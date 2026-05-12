package main

import (
	"bytes"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"time"

	"server/internal/payload"
	"server/internal/zigcore"
)

type app struct {
	instanceID string
	ready      bool
}

func main() {
	instanceID := os.Getenv("INSTANCE_ID")
	if instanceID == "" {
		instanceID = "1"
	}

	a := &app{instanceID: instanceID}
	if err := zigcore.Init("/app/vector-index"); err != nil {
		log.Printf("zig init failed: %v", err)
	} else {
		a.ready = true
	}
	defer zigcore.Shutdown()

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
	if r.Method != http.MethodGet {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	if !a.ready {
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = w.Write([]byte(`{"ready":false}`))
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write([]byte(`{"ready":true,"instance":"` + a.instanceID + `"}`))
}

func (a *app) handleFraudScore(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	if !a.ready {
		w.WriteHeader(http.StatusServiceUnavailable)
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, 4<<10))
	if err != nil {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	f, err := payload.Parse(body)
	if err != nil {
		w.WriteHeader(http.StatusBadRequest)
		return
	}

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
	if err != nil {
		w.WriteHeader(http.StatusServiceUnavailable)
		return
	}

	approved := score < 0.6
	res := buildResponse(approved, score, a.instanceID)
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Length", fmt.Sprintf("%d", len(res)))
	_, _ = w.Write(res)
}

func boolToU8(v bool) uint8 {
	if v {
		return 1
	}
	return 0
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
