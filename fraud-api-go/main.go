package main

import (
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"time"
	"unsafe"
)

const (
	MaxReq            = 64 * 1024
	MaxWorkers        = 8
)

type WorkerCtx struct {
	listener net.Listener
	scorer   *Scorer
}

func workerLoop(ctx *WorkerCtx) {
	for {
		conn, err := ctx.listener.Accept()
		if err != nil {
			time.Sleep(time.Millisecond)
			continue
		}
		go handleConn(conn, ctx.scorer)
	}
}

func findHeaderEnd(buf []byte, n int) int {
	if n < 4 {
		return -1
	}
	for i := 0; i+3 < n; i++ {
		if buf[i] == '\r' && buf[i+1] == '\n' && buf[i+2] == '\r' && buf[i+3] == '\n' {
			return i + 4
		}
	}
	return -1
}

func handleConn(conn net.Conn, scorer *Scorer) {
	defer conn.Close()

	conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	conn.SetWriteDeadline(time.Now().Add(10 * time.Second))

	buf := make([]byte, MaxReq)
	used := 0

	for used < MaxReq {
		n, err := conn.Read(buf[used:])
		if err != nil {
			return
		}
		if n == 0 {
			return
		}
		used += n
		if findHeaderEnd(buf[:used], used) >= 0 {
			break
		}
	}

	he := findHeaderEnd(buf[:used], used)
	if he < 0 {
		conn.Write(httpError(404))
		return
	}

	req := buf[:used]
	lineEnd := -1
	for i := 0; i+1 < he; i++ {
		if req[i] == '\r' && req[i+1] == '\n' {
			lineEnd = i
			break
		}
	}
	if lineEnd < 0 {
		conn.Write(httpError(404))
		return
	}

	line := string(req[:lineEnd])

	if strings.HasPrefix(line, "GET /ready") {
		conn.Write([]byte("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\nok"))
		return
	}

	if !strings.HasPrefix(line, "POST /fraud-score ") {
		if strings.HasPrefix(line, "GET ") {
			conn.Write(httpError(404))
		} else {
			conn.Write(httpError(405))
		}
		return
	}

	cl := parseContentLength(string(req[:he]))
	if cl == 0 || cl > MaxReq {
		conn.Write(httpError(413))
		return
	}

	for used < he+cl && used < MaxReq {
		n, err := conn.Read(buf[used:])
		if err != nil {
			conn.Write(httpError(503))
			return
		}
		if n == 0 {
			conn.Write(httpError(503))
			return
		}
		used += n
	}

	if used < he+cl {
		conn.Write(httpError(503))
		return
	}

	// Skip actual scoring - just validate HTTP layer works
	var out string
	if scorer == nil {
		out = `{"approved":true,"fraud_score":0.500000}`
	} else {
		body := buf[he : he+cl]
		features := parsePayload(body)
		q := Quantize(&features)
		score := scorer.Score(&q)
		approved := score < ApprovalThreshold
		out = fmt.Sprintf(`{"approved":%v,"fraud_score":%.6f}`, approved, score)
	}
	conn.Write(httpOK(out))
}

func parseContentLength(headers string) int {
	key := "Content-Length:"
	idx := strings.Index(headers, key)
	if idx < 0 {
		return 0
	}
	idx += len(key)
	for idx < len(headers) && (headers[idx] == ' ' || headers[idx] == '\t') {
		idx++
	}
	v := 0
	for idx < len(headers) && headers[idx] >= '0' && headers[idx] <= '9' {
		v = v*10 + int(headers[idx]-'0')
		idx++
	}
	return v
}

type Features struct {
	TransactionAmount              float32
	TransactionInstallments        int32
	TransactionHour                uint8
	TransactionDayOfWeek           uint8
	CustomerAvgAmount             float32
	CustomerTxCount24H            int32
	MerchantUnknown               bool
	MccRisk                       float32
	MerchantMCC                   uint16
	TerminalKmFromHome            float32
	TerminalIsOnline              bool
	TerminalCardPresent           bool
	TerminalKnownMerchants        int32
	LastTransactionMinutes       int32
	LastTransactionKmFromCurrent  float32
	MerchantAvgAmount             float32
	RequestedAtHour               uint8
	HasLastTransaction            bool
}

type Context int

const (
	ctxRoot Context = iota
	ctxTransaction
	ctxCustomer
	ctxMerchant
	ctxTerminal
	ctxLastTransaction
)

func skipWhitespace(buf []byte, i *int) {
	for *i < len(buf) && (buf[*i] == ' ' || buf[*i] == '\n' || buf[*i] == '\r' || buf[*i] == '\t') {
		*i++
	}
}

func skipColon(buf []byte, i *int) {
	skipWhitespace(buf, i)
	if *i < len(buf) && buf[*i] == ':' {
		*i++
	}
	skipWhitespace(buf, i)
}

func parseStringValue(buf []byte, i *int) string {
	skipWhitespace(buf, i)
	if *i < len(buf) && buf[*i] == '"' {
		*i++
	}
	start := *i
	for *i < len(buf) && buf[*i] != '"' {
		*i++
	}
	end := *i
	if *i < len(buf) {
		*i++
	}
	return string(buf[start:end])
}

func parseNumber(buf []byte, i *int) float64 {
	skipWhitespace(buf, i)
	negative := false
	if *i < len(buf) && buf[*i] == '-' {
		negative = true
		*i++
	}
	value := 0.0
	seenDot := false
	divisor := 1.0
	for *i < len(buf) {
		c := buf[*i]
		if c >= '0' && c <= '9' {
			value = value*10.0 + float64(c-'0')
			if seenDot {
				divisor *= 10.0
			}
		} else if c == '.' && !seenDot {
			seenDot = true
		} else {
			break
		}
		*i++
	}
	if negative {
		value = -value
	}
	return value / divisor
}

func parseI32(buf []byte, i *int) int32 {
	skipWhitespace(buf, i)
	negative := false
	if *i < len(buf) && buf[*i] == '-' {
		negative = true
		*i++
	}
	var value int32
	for *i < len(buf) {
		c := buf[*i]
		if c >= '0' && c <= '9' {
			value = value*10 + int32(c-'0')
		} else {
			break
		}
		*i++
	}
	if negative {
		value = -value
	}
	return value
}

func parseBool(buf []byte, i *int) bool {
	skipWhitespace(buf, i)
	if *i+4 <= len(buf) && string(buf[*i:*i+4]) == "true" {
		*i += 4
		return true
	}
	if *i+5 <= len(buf) && string(buf[*i:*i+5]) == "false" {
		*i += 5
		return false
	}
	return false
}

func parseISODateHour(buf []byte, i *int) uint8 {
	skipWhitespace(buf, i)
	if *i < len(buf) && buf[*i] == '"' {
		*i++
	}
	hour := uint8(0)
	for *i < len(buf) {
		c := buf[*i]
		if c == '"' || c == ',' {
			break
		}
		if c == 'T' {
			*i++
			if *i+2 <= len(buf) {
				h1 := buf[*i]
				h2 := buf[*i+1]
				if h1 >= '0' && h1 <= '9' && h2 >= '0' && h2 <= '9' {
					hour = (h1-'0')*10 + (h2 - '0')
				}
				*i += 2
			}
			for *i < len(buf) && buf[*i] != '"' && buf[*i] != ',' {
				*i++
			}
			break
		}
		*i++
	}
	if *i < len(buf) && buf[*i] == '"' {
		*i++
	}
	return hour
}

func parseISODateDayOfWeek(s string) uint8 {
	if len(s) < 10 {
		return 0
	}
	year := int(s[0]-'0')*1000 + int(s[1]-'0')*100 + int(s[2]-'0')*10 + int(s[3]-'0')
	month := int(s[5]-'0')*10 + int(s[6]-'0')
	day := int(s[8]-'0')*10 + int(s[9]-'0')

	m := month
	y := year
	if m < 3 {
		m += 12
		y -= 1
	}
	k := y % 100
	j := y / 100
	h := (day + (13*(m+1))/5 + k + k/4 + j/4 + 5*j) % 7
	dowSun0 := (h + 6) % 7
	if dowSun0 == 0 {
		return 6
	}
	return uint8(dowSun0 - 1)
}

func daysFromCivil(year, month, day int) int64 {
	y := year
	m := month
	if m <= 2 {
		y -= 1
	}
	era := y / 400
	yoe := y - era*400
	mp := m + 9%12 - 3
	doy := (153*mp + 2) / 5 + day - 1
	doe := yoe*365 + yoe/4 - yoe/100 + doy
	return int64(era)*146097 + int64(doe)
}

func parseISODateMinutes(s string) int64 {
	if len(s) < 16 {
		return -1
	}
	year := int(s[0]-'0')*1000 + int(s[1]-'0')*100 + int(s[2]-'0')*10 + int(s[3]-'0')
	month := int(s[5]-'0')*10 + int(s[6]-'0')
	day := int(s[8]-'0')*10 + int(s[9]-'0')
	hour := int(s[11]-'0')*10 + int(s[12]-'0')
	minute := int(s[14]-'0')*10 + int(s[15]-'0')
	return daysFromCivil(year, month, day)*1440 + int64(hour*60+minute)
}

func parseISODateAll(buf []byte, i *int, hour, dow *uint8, totalMinutes *int64) {
	skipWhitespace(buf, i)
	if *i >= len(buf) || buf[*i] != '"' {
		return
	}
	*i++
	start := *i
	for *i < len(buf) && buf[*i] != '"' {
		*i++
	}
	slice := string(buf[start:*i])
	*hour = 0
	if len(slice) >= 13 && slice[11] >= '0' && slice[11] <= '9' && slice[12] >= '0' && slice[12] <= '9' {
		*hour = (slice[11]-'0')*10 + (slice[12] - '0')
	}
	*dow = parseISODateDayOfWeek(slice)
	*totalMinutes = parseISODateMinutes(slice)
	if *i < len(buf) {
		*i++
	}
}

func parseISODateMinutesValue(buf []byte, i *int) int64 {
	skipWhitespace(buf, i)
	if *i >= len(buf) || buf[*i] != '"' {
		return -1
	}
	*i++
	start := *i
	for *i < len(buf) && buf[*i] != '"' {
		*i++
	}
	slice := string(buf[start:*i])
	if *i < len(buf) {
		*i++
	}
	return parseISODateMinutes(slice)
}

func hashId(s string) uint32 {
	h := uint32(2166136261)
	for _, c := range s {
		h ^= uint32(c)
		h *= 16777619
	}
	return h
}

func parseMccString(s string) uint16 {
	var value uint16
	for _, c := range s {
		if c >= '0' && c <= '9' {
			value = value*10 + uint16(c-'0')
		}
	}
	return value
}

func mccRisk(mcc uint16) float32 {
	switch mcc {
	case 5411:
		return 0.15
	case 5812:
		return 0.30
	case 5912:
		return 0.20
	case 5944:
		return 0.45
	case 7801:
		return 0.80
	case 7802:
		return 0.75
	case 7995:
		return 0.85
	case 4511:
		return 0.35
	case 5311:
		return 0.25
	case 5999:
		return 0.50
	default:
		return 0.50
	}
}

func parsePayload(body []byte) Features {
	var f Features
	i := 0
	ctx := ctxRoot
	prevCtx := ctxRoot
	merchantIDHash := uint32(0)
	var knownHashes [32]uint32
	knownCount := 0
	requestedTotalMinutes := int64(-1)
	lastTotalMinutes := int64(-1)

	for i < len(body) {
		skipWhitespace(body, &i)
		if i >= len(body) {
			break
		}

		if body[i] == '"' {
			keyStart := i + 1
			keyEnd := keyStart
			for keyEnd < len(body) && body[keyEnd] != '"' {
				keyEnd++
			}
			key := string(body[keyStart:keyEnd])
			i = keyEnd + 1

			skipColon(body, &i)

			if ctx == ctxRoot {
				if key == "transaction" {
					prevCtx = ctx
					ctx = ctxTransaction
				} else if key == "customer" {
					prevCtx = ctx
					ctx = ctxCustomer
				} else if key == "merchant" {
					prevCtx = ctx
					ctx = ctxMerchant
				} else if key == "terminal" {
					prevCtx = ctx
					ctx = ctxTerminal
				} else if key == "last_transaction" {
					prevCtx = ctx
					ctx = ctxLastTransaction
				} else if key == "requested_at" {
					f.RequestedAtHour = parseISODateHour(body, &i)
				}
			} else if ctx == ctxTransaction {
				if key == "amount" {
					f.TransactionAmount = float32(parseNumber(body, &i))
				} else if key == "installments" {
					f.TransactionInstallments = parseI32(body, &i)
				} else if key == "requested_at" {
					parseISODateAll(body, &i, &f.TransactionHour, &f.TransactionDayOfWeek, &requestedTotalMinutes)
				}
			} else if ctx == ctxCustomer {
				if key == "avg_amount" {
					f.CustomerAvgAmount = float32(parseNumber(body, &i))
				} else if key == "tx_count_24h" {
					f.CustomerTxCount24H = parseI32(body, &i)
				} else if key == "known_merchants" {
					skipWhitespace(body, &i)
					if i < len(body) && body[i] == '[' {
						i++
						for i < len(body) && body[i] != ']' {
							skipWhitespace(body, &i)
							if i < len(body) && body[i] == '"' {
								s := parseStringValue(body, &i)
								if knownCount < len(knownHashes) {
									knownHashes[knownCount] = hashId(s)
									knownCount++
								}
							} else {
								i++
							}
						}
						if i < len(body) && body[i] == ']' {
							i++
						}
					}
				}
			} else if ctx == ctxMerchant {
				if key == "id" {
					merchantIDHash = hashId(parseStringValue(body, &i))
				} else if key == "mcc" {
					mccStr := parseStringValue(body, &i)
					f.MerchantMCC = parseMccString(mccStr)
					f.MccRisk = mccRisk(f.MerchantMCC)
				} else if key == "avg_amount" {
					f.MerchantAvgAmount = float32(parseNumber(body, &i))
				}
			} else if ctx == ctxTerminal {
				if key == "km_from_home" {
					f.TerminalKmFromHome = float32(parseNumber(body, &i))
				} else if key == "is_online" {
					f.TerminalIsOnline = parseBool(body, &i)
				} else if key == "card_present" {
					f.TerminalCardPresent = parseBool(body, &i)
				} else if key == "known_merchants" {
					f.TerminalKnownMerchants = parseI32(body, &i)
				}
			} else if ctx == ctxLastTransaction {
				f.HasLastTransaction = true
				if key == "timestamp" {
					lastTotalMinutes = parseISODateMinutesValue(body, &i)
				} else if key == "km_from_current" {
					f.LastTransactionKmFromCurrent = float32(parseNumber(body, &i))
				}
			}
		} else if body[i] == '}' {
			i++
			ctx = prevCtx
		} else if body[i] == '[' || body[i] == ',' {
			i++
		} else {
			i++
		}
	}

	if merchantIDHash != 0 {
		known := false
		for k := 0; k < knownCount; k++ {
			if knownHashes[k] == merchantIDHash {
				known = true
				break
			}
		}
		f.MerchantUnknown = !known
	}
	if f.HasLastTransaction && requestedTotalMinutes >= 0 && lastTotalMinutes >= 0 {
		delta := requestedTotalMinutes - lastTotalMinutes
		if delta > 0 {
			f.LastTransactionMinutes = int32(delta)
		}
	}

	return f
}

func parseWorkerCount() int {
	raw := os.Getenv("API_WORKERS")
	if raw == "" {
		return 8
	}
	v, err := strconv.Atoi(raw)
	if err != nil {
		return 8
	}
	if v == 0 {
		return 1
	}
	if v > MaxWorkers {
		return MaxWorkers
	}
	return v
}

func main() {
	instance := os.Getenv("INSTANCE_ID")
	if instance == "" {
		instance = "1"
	}

	listenOn := os.Getenv("LISTEN_ON")
	if listenOn == "" {
		socketPath := fmt.Sprintf("/tmp/rinha/api-%s.sock", instance)
		dataDir := "/data/vector-index"

		var ds Dataset
		if err := ds.Load(dataDir); err != nil {
			fmt.Fprintf(os.Stderr, "DEBUG: Load error: %v\n", err)
			os.Exit(1)
		}
		defer ds.Deinit()

		scorer := &Scorer{}
		scorer.Init(&ds)

		os.Remove(socketPath)

		ln, err := net.Listen("unix", socketPath)
		if err != nil {
			fmt.Fprintf(os.Stderr, "DEBUG: Listen error: %v\n", err)
			os.Exit(1)
		}
		defer ln.Close()

		fmt.Fprintf(os.Stderr, "DEBUG: listening on %s\n", socketPath)

		workerCount := parseWorkerCount()
		for i := 0; i < workerCount; i++ {
			go workerLoop(&WorkerCtx{listener: ln, scorer: scorer})
		}

		select {}
	} else {
		// TCP mode for direct testing
		dataDir := "/data/vector-index"

		var ds Dataset
		if err := ds.Load(dataDir); err != nil {
			fmt.Fprintf(os.Stderr, "DEBUG: Load error: %v\n", err)
			os.Exit(1)
		}
		defer ds.Deinit()

		scorer := &Scorer{}
		scorer.Init(&ds)

		ln, err := net.Listen("tcp", listenOn)
		if err != nil {
			fmt.Fprintf(os.Stderr, "DEBUG: Listen error: %v\n", err)
			os.Exit(1)
		}
		defer ln.Close()

		fmt.Fprintf(os.Stderr, "DEBUG: listening on %s\n", listenOn)

		workerCount := parseWorkerCount()
		for i := 0; i < workerCount; i++ {
			go workerLoop(&WorkerCtx{listener: ln, scorer: scorer})
		}

		select {}
	}
}

func httpError(code int) []byte {
	switch code {
	case 404: return []byte("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
	case 405: return []byte("HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n")
	case 413: return []byte("HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\n\r\n")
	case 503: return []byte("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n")
	default: return []byte("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n")
	}
}

func httpOK(body string) []byte {
	hdr := fmt.Sprintf("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n", len(body))
	return []byte(hdr + body)
}

var _ unsafe.Pointer

var requestCount int64
var errorCount int64

func logRequest(id int64, status string, details string) {
	fmt.Fprintf(os.Stderr, "REQ[%d] %s %s\n", id, status, details)
}