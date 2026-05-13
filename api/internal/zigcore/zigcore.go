package zigcore

/*
#cgo LDFLAGS: -L${SRCDIR} -lzigscore
#include <stdint.h>
#include <stdlib.h>

typedef struct {
  float transaction_amount;
  int32_t transaction_installments;
  uint8_t transaction_hour;
  uint8_t transaction_day_of_week;
  float customer_avg_amount;
  int32_t customer_tx_count_24h;
  uint8_t merchant_unknown;
  float mcc_risk;
  uint16_t merchant_mcc;
  float terminal_km_from_home;
  uint8_t terminal_is_online;
  uint8_t terminal_card_present;
  int32_t terminal_known_merchants;
  int32_t last_transaction_minutes;
  float last_transaction_km_from_current;
  float merchant_avg_amount;
  uint8_t requested_at_hour;
  uint8_t has_last_transaction;
} ScoreReq;

typedef struct {
  float score;
  uint8_t err_code;
} ScoreRes;

extern uint32_t score_abi_version(void);
extern uint8_t score_init(const char* data_dir);
extern uint8_t score_eval(const ScoreReq* req, ScoreRes* res);
extern void score_shutdown(void);
typedef struct {
  uint64_t requests;
  uint64_t fallback_hits;
  uint64_t fallback_scanned_vectors;
  uint64_t cluster_scanned_vectors;
} CoreStats;
extern void score_stats(CoreStats* out);
*/
import "C"
import (
	"errors"
	"unsafe"
)

const expectedABIVersion = 1

var ErrInit = errors.New("zig core init failed")
var ErrEval = errors.New("zig core eval failed")
var ErrABI = errors.New("zig core abi version mismatch")

type Req struct {
	TransactionAmount        float32
	TransactionInstallments  int32
	TransactionHour          uint8
	TransactionDayOfWeek     uint8
	CustomerAvgAmount        float32
	CustomerTxCount24h       int32
	MerchantUnknown          uint8
	MccRisk                  float32
	MerchantMcc              uint16
	TerminalKmFromHome       float32
	TerminalIsOnline         uint8
	TerminalCardPresent      uint8
	TerminalKnownMerchants   int32
	LastTransactionMinutes   int32
	LastTransactionKmFromCur float32
	MerchantAvgAmount        float32
	RequestedAtHour          uint8
	HasLastTransaction       uint8
}

type Stats struct {
	Requests               uint64
	FallbackHits           uint64
	FallbackScannedVectors uint64
	ClusterScannedVectors  uint64
}

func Init(dataDir string) error {
	if uint32(C.score_abi_version()) != expectedABIVersion {
		return ErrABI
	}
	cstr := C.CString(dataDir)
	defer C.free(unsafe.Pointer(cstr))
	if C.score_init(cstr) != 0 {
		return ErrInit
	}
	return nil
}

func Eval(in Req) (float32, error) {
	creq := C.ScoreReq{
		transaction_amount:               C.float(in.TransactionAmount),
		transaction_installments:         C.int32_t(in.TransactionInstallments),
		transaction_hour:                 C.uint8_t(in.TransactionHour),
		transaction_day_of_week:          C.uint8_t(in.TransactionDayOfWeek),
		customer_avg_amount:              C.float(in.CustomerAvgAmount),
		customer_tx_count_24h:            C.int32_t(in.CustomerTxCount24h),
		merchant_unknown:                 C.uint8_t(in.MerchantUnknown),
		mcc_risk:                         C.float(in.MccRisk),
		merchant_mcc:                     C.uint16_t(in.MerchantMcc),
		terminal_km_from_home:            C.float(in.TerminalKmFromHome),
		terminal_is_online:               C.uint8_t(in.TerminalIsOnline),
		terminal_card_present:            C.uint8_t(in.TerminalCardPresent),
		terminal_known_merchants:         C.int32_t(in.TerminalKnownMerchants),
		last_transaction_minutes:         C.int32_t(in.LastTransactionMinutes),
		last_transaction_km_from_current: C.float(in.LastTransactionKmFromCur),
		merchant_avg_amount:              C.float(in.MerchantAvgAmount),
		requested_at_hour:                C.uint8_t(in.RequestedAtHour),
		has_last_transaction:             C.uint8_t(in.HasLastTransaction),
	}
	var cres C.ScoreRes
	if C.score_eval(&creq, &cres) != 0 || cres.err_code != 0 {
		return 0, ErrEval
	}
	return float32(cres.score), nil
}

func Shutdown() {
	C.score_shutdown()
}

func SnapshotStats() Stats {
	var cs C.CoreStats
	C.score_stats(&cs)
	return Stats{
		Requests:               uint64(cs.requests),
		FallbackHits:           uint64(cs.fallback_hits),
		FallbackScannedVectors: uint64(cs.fallback_scanned_vectors),
		ClusterScannedVectors:  uint64(cs.cluster_scanned_vectors),
	}
}
