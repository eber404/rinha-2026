package main

import "math"

type QueryVector [16]int16

func Quantize(f *Features) QueryVector {
	vec := QueryVector{}

	amount := f.TransactionAmount / 10000.0
	if amount > 1.0 {
		amount = 1.0
	}
	if amount < 0 {
		amount = 0
	}

	installments := float32(f.TransactionInstallments) / 12.0
	if installments > 1.0 {
		installments = 1.0
	}
	if installments < 0 {
		installments = 0
	}

	var amountVsAvg float32
	if f.CustomerAvgAmount > 0 {
		amountVsAvg = (f.TransactionAmount / f.CustomerAvgAmount) / 10.0
		if amountVsAvg > 1.0 {
			amountVsAvg = 1.0
		}
	}

	hour := float32(f.TransactionHour) / 23.0
	dayOfWeek := float32(f.TransactionDayOfWeek) / 6.0

	var minutesSinceLast float32
	if f.HasLastTransaction {
		minutesSinceLast = float32(f.LastTransactionMinutes) / 1440.0
		if minutesSinceLast > 1.0 {
			minutesSinceLast = 1.0
		}
	} else {
		minutesSinceLast = -1.0
	}

	var kmSinceLast float32
	if f.HasLastTransaction {
		kmSinceLast = f.LastTransactionKmFromCurrent / 1000.0
		if kmSinceLast > 1.0 {
			kmSinceLast = 1.0
		}
	} else {
		kmSinceLast = -1.0
	}

	kmFromHome := f.TerminalKmFromHome / 1000.0
	if kmFromHome > 1.0 {
		kmFromHome = 1.0
	}

	txCount := float32(f.CustomerTxCount24H) / 20.0
	if txCount > 1.0 {
		txCount = 1.0
	}

	merchantAvg := f.MerchantAvgAmount / 10000.0
	if merchantAvg > 1.0 {
		merchantAvg = 1.0
	}

	vec[0] = quantizeDim(amount, 1.0, 0.0)
	vec[1] = quantizeDim(installments, 1.0, 0.0)
	vec[2] = quantizeDim(amountVsAvg, 1.0, 0.0)
	vec[3] = quantizeDim(hour, 1.0, 0.0)
	vec[4] = quantizeDim(dayOfWeek, 1.0, 0.0)
	vec[5] = quantizeDim(minutesSinceLast, 1.0, 0.0)
	vec[6] = quantizeDim(kmSinceLast, 1.0, 0.0)
	vec[7] = quantizeDim(kmFromHome, 1.0, 0.0)
	vec[8] = quantizeDim(txCount, 1.0, 0.0)

	if f.TerminalIsOnline {
		vec[9] = quantizeDim(1.0, 1.0, 0.0)
	} else {
		vec[9] = quantizeDim(0.0, 1.0, 0.0)
	}

	if f.TerminalCardPresent {
		vec[10] = quantizeDim(1.0, 1.0, 0.0)
	} else {
		vec[10] = quantizeDim(0.0, 1.0, 0.0)
	}

	if f.MerchantUnknown {
		vec[11] = quantizeDim(1.0, 1.0, 0.0)
	} else {
		vec[11] = quantizeDim(0.0, 1.0, 0.0)
	}

	vec[12] = quantizeDim(f.MccRisk, 1.0, 0.0)
	vec[13] = quantizeDim(merchantAvg, 1.0, 0.0)

	return vec
}

func quantizeDim(value, scale, offset float32) int16 {
	normalized := (value - offset) / scale
	quantized := int16(math.Round(float64(normalized * 32767.0)))
	if quantized < -32768 {
		quantized = -32768
	} else if quantized > 32767 {
		quantized = 32767
	}
	return quantized
}