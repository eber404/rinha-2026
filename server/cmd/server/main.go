package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"hash/fnv"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"sync/atomic"
	"time"

	"server/internal/payload"
	"server/internal/zigcore"
)

type app struct {
	instanceID string
	ready      bool
	mockFixed  bool
	tracePct   int
	metrics    *metrics
}

type config struct {
	mockFixedResponse bool
	traceSamplePct    int
}

type requestTrace struct {
	Kind      string `json:"kind"`
	ReqID     string `json:"req_id"`
	Instance  string `json:"instance"`
	Status    int    `json:"status"`
	ReadUs    int64  `json:"t_read_us"`
	ParseUs   int64  `json:"t_parse_us"`
	EvalUs    int64  `json:"t_eval_us"`
	RespUs    int64  `json:"t_resp_us"`
	TotalUs   int64  `json:"t_total_us"`
	ParseErr  bool   `json:"parse_err"`
	EvalErr   bool   `json:"eval_err"`
	MockMode  bool   `json:"mock_mode"`
}

type metrics struct {
	requestsTotal      atomic.Int64
	readyRequests      atomic.Int64
	status200          atomic.Int64
	status400          atomic.Int64
	status405          atomic.Int64
	status503          atomic.Int64
	parseErrors        atomic.Int64
	evalErrors         atomic.Int64
	readErrors         atomic.Int64
	latencyTotalNs     atomic.Int64
	parseTotalNs       atomic.Int64
	evalTotalNs        atomic.Int64
	errorSamplesLogged atomic.Int64
}

func main() {
	cfg := loadConfigFromEnv()
	instanceID := os.Getenv("INSTANCE_ID")
	if instanceID == "" {
		instanceID = "1"
	}

	a := &app{instanceID: instanceID, metrics: &metrics{}, mockFixed: cfg.mockFixedResponse, tracePct: cfg.traceSamplePct}
	if a.mockFixed {
		a.ready = true
		log.Printf("instance=%s mock mode enabled (fixed response)", instanceID)
	} else if err := zigcore.Init("/app/fraud-engine/vector-index"); err != nil {
		log.Printf("zig init failed: %v", err)
	} else {
		a.ready = true
	}
	if !a.mockFixed {
		defer zigcore.Shutdown()
	}
	go a.reportMetrics()

	socketPath := fmt.Sprintf("/tmp/rinha/api-%s.sock", instanceID)
	_ = os.Remove(socketPath)
	ln, err := net.Listen("unix", socketPath)
	if err != nil {
		log.Fatalf("listen uds failed: %v", err)
	}
	defer ln.Close()
	if err := os.Chmod(socketPath, 0o777); err != nil {
		log.Fatalf("chmod uds failed: %v", err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/ready", a.handleReady)
	mux.HandleFunc("/fraud-score", a.handleFraudScore)

	srv := &http.Server{
		Handler:        mux,
		ReadTimeout:    5 * time.Second,
		WriteTimeout:   5 * time.Second,
		MaxHeaderBytes: 4 << 10,
	}

	log.Printf("server-%s listening on %s", instanceID, socketPath)
	if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
		log.Fatalf("server error: %v", err)
	}
}

func (a *app) handleReady(w http.ResponseWriter, r *http.Request) {
	a.metrics.readyRequests.Add(1)
	if r.Method != http.MethodGet {
		a.metrics.status405.Add(1)
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	if !a.ready {
		a.metrics.status503.Add(1)
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = w.Write([]byte(`{"ready":false}`))
		return
	}
	a.metrics.status200.Add(1)
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write([]byte(`{"ready":true,"instance":"` + a.instanceID + `"}`))
}

func (a *app) handleFraudScore(w http.ResponseWriter, r *http.Request) {
	started := time.Now()
	status := http.StatusOK
	var parseErr bool
	var evalErr bool
	var readDurUs int64
	var parseDurUs int64
	var evalDurUs int64
	var respDurUs int64
	reqID := r.Header.Get("X-Req-Id")
	if reqID == "" {
		reqID = fmt.Sprintf("%s-%d", a.instanceID, started.UnixNano())
	}
	a.metrics.requestsTotal.Add(1)
	if r.Method != http.MethodPost {
		a.metrics.status405.Add(1)
		status = http.StatusMethodNotAllowed
		w.WriteHeader(http.StatusMethodNotAllowed)
		a.maybeTrace(reqID, status, readDurUs, parseDurUs, evalDurUs, respDurUs, started, parseErr, evalErr)
		return
	}
	if !a.ready {
		a.metrics.status503.Add(1)
		status = http.StatusServiceUnavailable
		w.WriteHeader(http.StatusServiceUnavailable)
		a.maybeTrace(reqID, status, readDurUs, parseDurUs, evalDurUs, respDurUs, started, parseErr, evalErr)
		return
	}
	readStart := time.Now()
	body, err := io.ReadAll(io.LimitReader(r.Body, 4<<10))
	readDurUs = time.Since(readStart).Microseconds()
	if err != nil {
		a.metrics.readErrors.Add(1)
		a.metrics.status400.Add(1)
		status = http.StatusBadRequest
		w.WriteHeader(http.StatusBadRequest)
		a.sampleErrorLog("read_body", err, nil)
		a.maybeTrace(reqID, status, readDurUs, parseDurUs, evalDurUs, respDurUs, started, parseErr, evalErr)
		return
	}
	parseStart := time.Now()
	f, err := payload.Parse(body)
	a.metrics.parseTotalNs.Add(time.Since(parseStart).Nanoseconds())
	parseDurUs = time.Since(parseStart).Microseconds()
	if err != nil {
		parseErr = true
		a.metrics.parseErrors.Add(1)
		a.metrics.status400.Add(1)
		status = http.StatusBadRequest
		w.WriteHeader(http.StatusBadRequest)
		a.sampleErrorLog("parse_payload", err, body)
		a.maybeTrace(reqID, status, readDurUs, parseDurUs, evalDurUs, respDurUs, started, parseErr, evalErr)
		return
	}

	if a.mockFixed {
		respStart := time.Now()
		res := buildResponse(true, 0.01, a.instanceID)
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Content-Length", fmt.Sprintf("%d", len(res)))
		_, _ = w.Write(res)
		respDurUs = time.Since(respStart).Microseconds()
		a.metrics.status200.Add(1)
		a.metrics.latencyTotalNs.Add(time.Since(started).Nanoseconds())
		a.maybeTrace(reqID, status, readDurUs, parseDurUs, evalDurUs, respDurUs, started, parseErr, evalErr)
		return
	}

	evalStart := time.Now()
	score, err := zigcore.Eval(zigcore.Req{
		TransactionAmount:        f.TransactionAmount,
		TransactionInstallments:  f.TransactionInstallments,
		TransactionHour:          f.TransactionHour,
		TransactionDayOfWeek:     f.TransactionDayOfWeek,
		CustomerAvgAmount:        f.CustomerAvgAmount,
		CustomerTxCount24h:       f.CustomerTxCount24h,
		MerchantUnknown:          boolToU8(f.MerchantUnknown),
		MccRisk:                  f.MccRisk,
		MerchantMcc:              f.MerchantMcc,
		TerminalKmFromHome:       f.TerminalKmFromHome,
		TerminalIsOnline:         boolToU8(f.TerminalIsOnline),
		TerminalCardPresent:      boolToU8(f.TerminalCardPresent),
		TerminalKnownMerchants:   f.TerminalKnownMerchants,
		LastTransactionMinutes:   f.LastTransactionMinutes,
		LastTransactionKmFromCur: f.LastTransactionKmCurrent,
		MerchantAvgAmount:        f.MerchantAvgAmount,
		RequestedAtHour:          f.RequestedAtHour,
		HasLastTransaction:       boolToU8(f.HasLastTransaction),
	})
	a.metrics.evalTotalNs.Add(time.Since(evalStart).Nanoseconds())
	evalDurUs = time.Since(evalStart).Microseconds()
	if err != nil {
		evalErr = true
		a.metrics.evalErrors.Add(1)
		a.metrics.status503.Add(1)
		status = http.StatusServiceUnavailable
		w.WriteHeader(http.StatusServiceUnavailable)
		a.sampleErrorLog("zig_eval", err, nil)
		a.maybeTrace(reqID, status, readDurUs, parseDurUs, evalDurUs, respDurUs, started, parseErr, evalErr)
		return
	}

	approved := score < 0.6
	respStart := time.Now()
	res := buildResponse(approved, score, a.instanceID)
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Length", fmt.Sprintf("%d", len(res)))
	_, _ = w.Write(res)
	respDurUs = time.Since(respStart).Microseconds()
	a.metrics.status200.Add(1)
	a.metrics.latencyTotalNs.Add(time.Since(started).Nanoseconds())
	a.maybeTrace(reqID, status, readDurUs, parseDurUs, evalDurUs, respDurUs, started, parseErr, evalErr)
}

func (a *app) sampleErrorLog(kind string, err error, body []byte) {
	if a.metrics.errorSamplesLogged.Load() >= 50 {
		return
	}
	idx := a.metrics.errorSamplesLogged.Add(1)
	if idx > 50 {
		return
	}
	if len(body) > 280 {
		body = body[:280]
	}
	log.Printf("instance=%s err_kind=%s err=%v body=%q", a.instanceID, kind, err, body)
}

func (a *app) reportMetrics() {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()

	var prevReq int64
	var prev200 int64
	var prev400 int64
	var prev405 int64
	var prev503 int64
	var prevParseErr int64
	var prevEvalErr int64
	var prevReadErr int64
	var prevZigReq uint64
	var prevZigFallback uint64
	var prevZigFallbackScanned uint64
	var prevZigClusterScanned uint64

	for range ticker.C {
		req := a.metrics.requestsTotal.Load()
		s200 := a.metrics.status200.Load()
		s400 := a.metrics.status400.Load()
		s405 := a.metrics.status405.Load()
		s503 := a.metrics.status503.Load()
		parseErr := a.metrics.parseErrors.Load()
		evalErr := a.metrics.evalErrors.Load()
		readErr := a.metrics.readErrors.Load()

		dReq := req - prevReq
		d200 := s200 - prev200
		d400 := s400 - prev400
		d405 := s405 - prev405
		d503 := s503 - prev503
		dParseErr := parseErr - prevParseErr
		dEvalErr := evalErr - prevEvalErr
		dReadErr := readErr - prevReadErr

		prevReq, prev200, prev400, prev405, prev503 = req, s200, s400, s405, s503
		prevParseErr, prevEvalErr, prevReadErr = parseErr, evalErr, readErr

		latAvgMs := avgMs(a.metrics.latencyTotalNs.Load(), s200)
		parseAvgMs := avgMs(a.metrics.parseTotalNs.Load(), req)
		evalAvgMs := avgMs(a.metrics.evalTotalNs.Load(), req-parseErr-readErr)

		z := zigcore.SnapshotStats()
		dZigReq := z.Requests - prevZigReq
		dZigFallback := z.FallbackHits - prevZigFallback
		dZigFallbackScanned := z.FallbackScannedVectors - prevZigFallbackScanned
		dZigClusterScanned := z.ClusterScannedVectors - prevZigClusterScanned
		prevZigReq = z.Requests
		prevZigFallback = z.FallbackHits
		prevZigFallbackScanned = z.FallbackScannedVectors
		prevZigClusterScanned = z.ClusterScannedVectors

		fallbackRate := 0.0
		if dZigReq > 0 {
			fallbackRate = float64(dZigFallback) / float64(dZigReq)
		}

		log.Printf("instance=%s metrics window=5s req=%d ok200=%d bad400=%d m405=%d svc503=%d parse_err=%d eval_err=%d read_err=%d avg_ms_total=%.3f avg_ms_parse=%.3f avg_ms_eval=%.3f zig_req=%d zig_fallback=%d zig_fallback_rate=%.3f zig_cluster_scan=%d zig_fallback_scan=%d", a.instanceID, dReq, d200, d400, d405, d503, dParseErr, dEvalErr, dReadErr, latAvgMs, parseAvgMs, evalAvgMs, dZigReq, dZigFallback, fallbackRate, dZigClusterScanned, dZigFallbackScanned)
	}
}

func avgMs(totalNs int64, n int64) float64 {
	if n <= 0 {
		return 0
	}
	return float64(totalNs) / float64(n) / 1_000_000
}

func boolToU8(v bool) uint8 {
	if v {
		return 1
	}
	return 0
}

func loadConfigFromEnv() config {
	tracePct := 5
	if raw := os.Getenv("TRACE_SAMPLE_PCT"); raw != "" {
		if n, err := strconv.Atoi(raw); err == nil {
			if n < 0 {
				n = 0
			}
			if n > 100 {
				n = 100
			}
			tracePct = n
		}
	}
	return config{mockFixedResponse: os.Getenv("MOCK_MODE") == "fixed", traceSamplePct: tracePct}
}

func (a *app) shouldTrace(reqID string) bool {
	if a.tracePct <= 0 {
		return false
	}
	if a.tracePct >= 100 {
		return true
	}
	h := fnv.New32a()
	_, _ = h.Write([]byte(reqID))
	return int(h.Sum32()%100) < a.tracePct
}

func (a *app) maybeTrace(reqID string, status int, readDurUs int64, parseDurUs int64, evalDurUs int64, respDurUs int64, started time.Time, parseErr bool, evalErr bool) {
	if !a.shouldTrace(reqID) {
		return
	}
	t := requestTrace{
		Kind:     "req_trace",
		ReqID:    reqID,
		Instance: a.instanceID,
		Status:   status,
		ReadUs:   readDurUs,
		ParseUs:  parseDurUs,
		EvalUs:   evalDurUs,
		RespUs:   respDurUs,
		TotalUs:  time.Since(started).Microseconds(),
		ParseErr: parseErr,
		EvalErr:  evalErr,
		MockMode: a.mockFixed,
	}
	b, err := json.Marshal(t)
	if err != nil {
		return
	}
	log.Print(string(b))
}

func buildResponse(approved bool, score float32, instance string) []byte {
	b := bytes.NewBuffer(make([]byte, 0, 96))
	b.WriteString(`{"approved":`)
	if approved {
		b.WriteString("true")
	} else {
		b.WriteString("false")
	}
	b.WriteString(`,"fraud_score":`)
	b.WriteString(fmt.Sprintf("%g", score))
	b.WriteString(`,"instance":"`)
	b.WriteString(instance)
	b.WriteString(`"}`)
	return b.Bytes()
}
