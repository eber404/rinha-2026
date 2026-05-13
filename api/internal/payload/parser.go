package payload

import (
	"bytes"
	"errors"
	"hash/fnv"
)

var ErrInvalid = errors.New("invalid payload")

type Features struct {
	TransactionAmount        float32
	TransactionInstallments  int32
	TransactionHour          uint8
	TransactionDayOfWeek     uint8
	CustomerAvgAmount        float32
	CustomerTxCount24h       int32
	MerchantUnknown          bool
	MccRisk                  float32
	MerchantMcc              uint16
	TerminalKmFromHome       float32
	TerminalIsOnline         bool
	TerminalCardPresent      bool
	TerminalKnownMerchants   int32
	LastTransactionMinutes   int32
	LastTransactionKmCurrent float32
	MerchantAvgAmount        float32
	RequestedAtHour          uint8
	HasLastTransaction       bool
}

type ctx uint8

const (
	ctxRoot ctx = iota
	ctxTransaction
	ctxCustomer
	ctxMerchant
	ctxTerminal
	ctxLastTransaction
)

func Parse(body []byte) (Features, error) {
	f := Features{MerchantUnknown: true, MccRisk: 0.5}
	stack := [8]ctx{ctxRoot}
	depth := 1
	var pendingKey []byte
	var merchantHash uint32
	known := [32]uint32{}
	knownCount := 0

	i := 0
	for i < len(body) {
		i = skipWS(body, i)
		if i >= len(body) {
			break
		}
		switch body[i] {
		case '{':
			next := stack[depth-1]
			switch {
			case bytes.Equal(pendingKey, []byte("transaction")):
				next = ctxTransaction
			case bytes.Equal(pendingKey, []byte("customer")):
				next = ctxCustomer
			case bytes.Equal(pendingKey, []byte("merchant")):
				next = ctxMerchant
			case bytes.Equal(pendingKey, []byte("terminal")):
				next = ctxTerminal
			case bytes.Equal(pendingKey, []byte("last_transaction")):
				next = ctxLastTransaction
				f.HasLastTransaction = true
			}
			if depth < len(stack) {
				stack[depth] = next
				depth++
			}
			pendingKey = nil
			i++
		case '}':
			if depth > 1 {
				depth--
			}
			i++
		case '"':
			k, ni, ok := parseString(body, i)
			if !ok {
				return Features{}, ErrInvalid
			}
			i = skipWS(body, ni)
			if i < len(body) && body[i] == ':' {
				i = skipWS(body, i+1)
				pendingKey = k
				cur := stack[depth-1]
				if cur == ctxRoot && bytes.Equal(k, []byte("requested_at")) {
					s, ni2, ok2 := parseString(body, i)
					if !ok2 {
						return Features{}, ErrInvalid
					}
					f.RequestedAtHour = parseHour(s)
					i = ni2
					pendingKey = nil
					continue
				}
				handled, ni3 := parseValueForKey(cur, k, body, i, &f, &merchantHash, &known, &knownCount)
				if handled {
					i = ni3
					pendingKey = nil
				}
			} else {
				i = ni
			}
		default:
			i++
		}
	}

	if merchantHash != 0 {
		knownMerch := false
		for j := 0; j < knownCount; j++ {
			if known[j] == merchantHash {
				knownMerch = true
				break
			}
		}
		f.MerchantUnknown = !knownMerch
	}

	return f, nil
}

func parseValueForKey(cur ctx, key []byte, body []byte, i int, f *Features, merchantHash *uint32, known *[32]uint32, knownCount *int) (bool, int) { /* same as other module */
	switch cur {
	case ctxTransaction:
		switch {
		case bytes.Equal(key, []byte("amount")):
			v, ni, ok := parseFloat(body, i)
			if !ok {
				return false, i
			}
			f.TransactionAmount = v
			return true, ni
		case bytes.Equal(key, []byte("installments")):
			v, ni, ok := parseInt(body, i)
			if !ok {
				return false, i
			}
			f.TransactionInstallments = v
			return true, ni
		case bytes.Equal(key, []byte("requested_at")):
			s, ni, ok := parseString(body, i)
			if !ok {
				return false, i
			}
			f.TransactionHour = parseHour(s)
			f.TransactionDayOfWeek = parseDOW(s)
			return true, ni
		}
	case ctxCustomer:
		switch {
		case bytes.Equal(key, []byte("avg_amount")):
			v, ni, ok := parseFloat(body, i)
			if !ok {
				return false, i
			}
			f.CustomerAvgAmount = v
			return true, ni
		case bytes.Equal(key, []byte("tx_count_24h")):
			v, ni, ok := parseInt(body, i)
			if !ok {
				return false, i
			}
			f.CustomerTxCount24h = v
			return true, ni
		case bytes.Equal(key, []byte("known_merchants")):
			return true, parseKnownMerchants(body, i, known, knownCount)
		}
	case ctxMerchant:
		switch {
		case bytes.Equal(key, []byte("id")):
			s, ni, ok := parseString(body, i)
			if !ok {
				return false, i
			}
			*merchantHash = hashID(s)
			return true, ni
		case bytes.Equal(key, []byte("mcc")):
			s, ni, ok := parseString(body, i)
			if !ok {
				return false, i
			}
			f.MerchantMcc = parseMCC(s)
			return true, ni
		case bytes.Equal(key, []byte("avg_amount")):
			v, ni, ok := parseFloat(body, i)
			if !ok {
				return false, i
			}
			f.MerchantAvgAmount = v
			return true, ni
		}
	case ctxTerminal:
		switch {
		case bytes.Equal(key, []byte("km_from_home")):
			v, ni, ok := parseFloat(body, i)
			if !ok {
				return false, i
			}
			f.TerminalKmFromHome = v
			return true, ni
		case bytes.Equal(key, []byte("is_online")):
			v, ni, ok := parseBool(body, i)
			if !ok {
				return false, i
			}
			f.TerminalIsOnline = v
			return true, ni
		case bytes.Equal(key, []byte("card_present")):
			v, ni, ok := parseBool(body, i)
			if !ok {
				return false, i
			}
			f.TerminalCardPresent = v
			return true, ni
		case bytes.Equal(key, []byte("known_merchants")):
			v, ni, ok := parseInt(body, i)
			if !ok {
				return false, i
			}
			f.TerminalKnownMerchants = v
			return true, ni
		}
	case ctxLastTransaction:
		switch {
		case bytes.Equal(key, []byte("minutes")):
			v, ni, ok := parseInt(body, i)
			if !ok {
				return false, i
			}
			f.LastTransactionMinutes = v
			return true, ni
		case bytes.Equal(key, []byte("km_from_current")):
			v, ni, ok := parseFloat(body, i)
			if !ok {
				return false, i
			}
			f.LastTransactionKmCurrent = v
			return true, ni
		}
	}
	return false, i
}

func skipWS(b []byte, i int) int {
	for i < len(b) && (b[i] == ' ' || b[i] == '\n' || b[i] == '\t' || b[i] == '\r') {
		i++
	}
	return i
}
func parseString(b []byte, i int) ([]byte, int, bool) {
	if i >= len(b) || b[i] != '"' {
		return nil, i, false
	}
	i++
	s := i
	for i < len(b) {
		if b[i] == '\\' {
			i += 2
			continue
		}
		if b[i] == '"' {
			return b[s:i], i + 1, true
		}
		i++
	}
	return nil, i, false
}
func parseFloat(b []byte, i int) (float32, int, bool) {
	start := i
	if i < len(b) && (b[i] == '-' || b[i] == '+') {
		i++
	}
	for i < len(b) && ((b[i] >= '0' && b[i] <= '9') || b[i] == '.') {
		i++
	}
	if start == i {
		return 0, i, false
	}
	neg := false
	j := start
	if b[j] == '-' {
		neg = true
		j++
	}
	var v float32
	for j < i && b[j] >= '0' && b[j] <= '9' {
		v = v*10 + float32(b[j]-'0')
		j++
	}
	if j < i && b[j] == '.' {
		j++
		frac := float32(1)
		for j < i && b[j] >= '0' && b[j] <= '9' {
			frac *= 10
			v += float32(b[j]-'0') / frac
			j++
		}
	}
	if neg {
		v = -v
	}
	return v, i, true
}
func parseInt(b []byte, i int) (int32, int, bool) {
	if i >= len(b) {
		return 0, i, false
	}
	neg := false
	if b[i] == '-' {
		neg = true
		i++
	}
	s := i
	var v int32
	for i < len(b) && b[i] >= '0' && b[i] <= '9' {
		v = v*10 + int32(b[i]-'0')
		i++
	}
	if s == i {
		return 0, i, false
	}
	if neg {
		v = -v
	}
	return v, i, true
}
func parseBool(b []byte, i int) (bool, int, bool) {
	if i+4 <= len(b) && bytes.Equal(b[i:i+4], []byte("true")) {
		return true, i + 4, true
	}
	if i+5 <= len(b) && bytes.Equal(b[i:i+5], []byte("false")) {
		return false, i + 5, true
	}
	return false, i, false
}
func parseKnownMerchants(b []byte, i int, known *[32]uint32, count *int) int {
	i = skipWS(b, i)
	if i >= len(b) || b[i] != '[' {
		return i
	}
	i++
	for i < len(b) {
		i = skipWS(b, i)
		if i < len(b) && b[i] == ']' {
			return i + 1
		}
		if i < len(b) && b[i] == ',' {
			i++
			continue
		}
		s, ni, ok := parseString(b, i)
		if !ok {
			i++
			continue
		}
		if *count < len(known) {
			known[*count] = hashID(s)
			*count++
		}
		i = ni
	}
	return i
}
func parseHour(s []byte) uint8 {
	if len(s) >= 13 && s[11] >= '0' && s[11] <= '9' && s[12] >= '0' && s[12] <= '9' {
		return uint8((s[11]-'0')*10 + (s[12] - '0'))
	}
	return 0
}
func parseDOW(s []byte) uint8 {
	if len(s) < 10 {
		return 0
	}
	year := int(s[0]-'0')*1000 + int(s[1]-'0')*100 + int(s[2]-'0')*10 + int(s[3]-'0')
	month := int(s[5]-'0')*10 + int(s[6]-'0')
	day := int(s[8]-'0')*10 + int(s[9]-'0')
	if month < 3 {
		month += 12
		year--
	}
	k := year % 100
	j := year / 100
	h := (day + (13*(month+1))/5 + k + k/4 + j/4 + 5*j) % 7
	sun0 := (h + 6) % 7
	if sun0 == 0 {
		return 6
	}
	return uint8(sun0 - 1)
}
func hashID(s []byte) uint32 { h := fnv.New32a(); _, _ = h.Write(s); return h.Sum32() }
func parseMCC(s []byte) uint16 {
	var v uint16
	for _, c := range s {
		if c >= '0' && c <= '9' {
			v = v*10 + uint16(c-'0')
		}
	}
	return v
}
