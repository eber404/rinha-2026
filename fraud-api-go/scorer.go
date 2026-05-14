package main

import (
	"encoding/binary"
	"fmt"
	"math"
	"os"
	"sync/atomic"
	"unsafe"

	"golang.org/x/sys/unix"
)

const (
	VectorsSize        = 96000000
	LabelsSize         = 3000000
	CentroidsSize      = 4096
	ClusterOffsetsSize = 2048
	VectDim            = 16
	VectorBytes        = 32
	K                  = 5
	NPROBE             = 16
	TotalScanBudget    = 6000
	Pass1Percent       = 60
	ApprovalThreshold  = 0.6
)

type TopK struct {
	distances [K]int64
	indices   [K]uint32
	count     uint32
}

func (t *TopK) Init() {
	t.count = 0
	for i := range t.distances[:] {
		t.distances[i] = 0
		t.indices[i] = 0
	}
}

func (t *TopK) Insert(dist int64, idx uint32) bool {
	if t.count < K {
		pos := t.count
		for pos > 0 && dist < t.distances[pos-1] {
			t.distances[pos] = t.distances[pos-1]
			t.indices[pos] = t.indices[pos-1]
			pos--
		}
		t.distances[pos] = dist
		t.indices[pos] = idx
		t.count++
		return true
	}
	if dist >= t.distances[K-1] {
		return false
	}
	pos := K - 1
	for pos > 0 && dist < t.distances[pos-1] {
		t.distances[pos] = t.distances[pos-1]
		t.indices[pos] = t.indices[pos-1]
		pos--
	}
	t.distances[pos] = dist
	t.indices[pos] = idx
	return true
}

func (t *TopK) InsertUnique(dist int64, idx uint32) {
	for i := uint32(0); i < t.count; i++ {
		if t.indices[i] == idx {
			return
		}
	}
	t.Insert(dist, idx)
}

type Record struct {
	start uint32
	end   uint32
}

type Dataset struct {
	vectors_fd         int
	labels_fd          int
	centroids_fd       int
	cluster_offsets_fd int

	vectors_mmap         []byte
	labels_mmap          []byte
	centroids_mmap       []byte
	cluster_offsets_mmap []byte

	cluster_offsets_cache [257]uint32
	cluster_count          uint32
	nVectors              uint32
}

func decodeU32Le(b []byte) uint32 {
	return binary.LittleEndian.Uint32(b)
}

func (d *Dataset) Load(dataDir string) error {
	vecs, err := mmapFile(dataDir+"/vectors_i16.bin", VectorsSize)
	if err != nil {
		return fmt.Errorf("vectors: %w", err)
	}
	d.vectors_mmap = vecs

	labels, err := mmapFile(dataDir+"/labels.bin", LabelsSize)
	if err != nil {
		return fmt.Errorf("labels: %w", err)
	}
	d.labels_mmap = labels

	cents, err := mmapFile(dataDir+"/centroids_i8.bin", CentroidsSize)
	if err != nil {
		return fmt.Errorf("centroids: %w", err)
	}
	d.centroids_mmap = cents

	offs, err := mmapFile(dataDir+"/cluster_offsets.bin", ClusterOffsetsSize)
	if err != nil {
		return fmt.Errorf("cluster_offsets: %w", err)
	}
	d.cluster_offsets_mmap = offs

	if len(d.vectors_mmap)%VectorBytes != 0 {
		return os.ErrInvalid
	}
	d.nVectors = uint32(len(d.vectors_mmap) / VectorBytes)

	clusterRecords := uint32(len(d.cluster_offsets_mmap) / 8)
	if clusterRecords == 0 || clusterRecords > 256 {
		return os.ErrInvalid
	}
	d.cluster_count = clusterRecords

	for c := uint32(0); c < clusterRecords; c++ {
		base := c * 8
		start := decodeU32Le(d.cluster_offsets_mmap[base : base+4])
		end := decodeU32Le(d.cluster_offsets_mmap[base+4 : base+8])
		d.cluster_offsets_cache[c] = start
		d.cluster_offsets_cache[c+1] = end
	}

	return nil
}

func mmapFile(path string, size int) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	data, err := unix.Mmap(int(f.Fd()), 0, size, unix.PROT_READ, unix.MAP_SHARED)
	if err != nil {
		return nil, err
	}
	return data, nil
}

func (d *Dataset) Deinit() {
	if len(d.vectors_mmap) > 0 {
		unix.Munmap(d.vectors_mmap)
	}
	if len(d.labels_mmap) > 0 {
		unix.Munmap(d.labels_mmap)
	}
	if len(d.centroids_mmap) > 0 {
		unix.Munmap(d.centroids_mmap)
	}
	if len(d.cluster_offsets_mmap) > 0 {
		unix.Munmap(d.cluster_offsets_mmap)
	}
}

func (d *Dataset) LabelAt(idx uint32) uint8 {
	if idx >= uint32(len(d.labels_mmap)) {
		return 0
	}
	return d.labels_mmap[idx]
}

func (d *Dataset) ClusterRange(cluster uint32) Record {
	if cluster >= d.cluster_count {
		return Record{}
	}
	return Record{
		start: d.cluster_offsets_cache[cluster],
		end:   d.cluster_offsets_cache[cluster+1],
	}
}

// readVec16I16 reads 16 int16 values from 32 bytes (little-endian)
func readVec16I16(vbytes []byte) (v [VectDim]int16) {
	v[0] = int16(uint16(vbytes[0]) | (uint16(vbytes[1]) << 8))
	v[1] = int16(uint16(vbytes[2]) | (uint16(vbytes[3]) << 8))
	v[2] = int16(uint16(vbytes[4]) | (uint16(vbytes[5]) << 8))
	v[3] = int16(uint16(vbytes[6]) | (uint16(vbytes[7]) << 8))
	v[4] = int16(uint16(vbytes[8]) | (uint16(vbytes[9]) << 8))
	v[5] = int16(uint16(vbytes[10]) | (uint16(vbytes[11]) << 8))
	v[6] = int16(uint16(vbytes[12]) | (uint16(vbytes[13]) << 8))
	v[7] = int16(uint16(vbytes[14]) | (uint16(vbytes[15]) << 8))
	v[8] = int16(uint16(vbytes[16]) | (uint16(vbytes[17]) << 8))
	v[9] = int16(uint16(vbytes[18]) | (uint16(vbytes[19]) << 8))
	v[10] = int16(uint16(vbytes[20]) | (uint16(vbytes[21]) << 8))
	v[11] = int16(uint16(vbytes[22]) | (uint16(vbytes[23]) << 8))
	v[12] = int16(uint16(vbytes[24]) | (uint16(vbytes[25]) << 8))
	v[13] = int16(uint16(vbytes[26]) | (uint16(vbytes[27]) << 8))
	v[14] = int16(uint16(vbytes[28]) | (uint16(vbytes[29]) << 8))
	v[15] = int16(uint16(vbytes[30]) | (uint16(vbytes[31]) << 8))
	return
}

// distance computes squared Euclidean distance between two 16-dim vectors
func distance(q, v *[VectDim]int16) int64 {
	d0 := int64((*q)[0]) - int64((*v)[0])
	d1 := int64((*q)[1]) - int64((*v)[1])
	d2 := int64((*q)[2]) - int64((*v)[2])
	d3 := int64((*q)[3]) - int64((*v)[3])
	d4 := int64((*q)[4]) - int64((*v)[4])
	d5 := int64((*q)[5]) - int64((*v)[5])
	d6 := int64((*q)[6]) - int64((*v)[6])
	d7 := int64((*q)[7]) - int64((*v)[7])
	d8 := int64((*q)[8]) - int64((*v)[8])
	d9 := int64((*q)[9]) - int64((*v)[9])
	d10 := int64((*q)[10]) - int64((*v)[10])
	d11 := int64((*q)[11]) - int64((*v)[11])
	d12 := int64((*q)[12]) - int64((*v)[12])
	d13 := int64((*q)[13]) - int64((*v)[13])
	d14 := int64((*q)[14]) - int64((*v)[14])
	d15 := int64((*q)[15]) - int64((*v)[15])
	return d0*d0 + d1*d1 + d2*d2 + d3*d3 + d4*d4 + d5*d5 + d6*d6 + d7*d7 + d8*d8 + d9*d9 + d10*d10 + d11*d11 + d12*d12 + d13*d13 + d14*d14 + d15*d15
}

// distanceFromBytes computes distance using on-stack vector
func distanceFromBytes(q *[VectDim]int16, vbytes []byte) int64 {
	v := readVec16I16(vbytes)
	return distance(q, &v)
}

// queryToVec16I8 quantizes query to int8 with scaling
func queryToVec16I8(q *[VectDim]int16) [VectDim]int8 {
	var result [VectDim]int8
	q0 := (*q)[0] / 258
	q1 := (*q)[1] / 258
	q2 := (*q)[2] / 258
	q3 := (*q)[3] / 258
	q4 := (*q)[4] / 258
	q5 := (*q)[5] / 258
	q6 := (*q)[6] / 258
	q7 := (*q)[7] / 258
	q8 := (*q)[8] / 258
	q9 := (*q)[9] / 258
	q10 := (*q)[10] / 258
	q11 := (*q)[11] / 258
	q12 := (*q)[12] / 258
	q13 := (*q)[13] / 258
	q14 := (*q)[14] / 258
	q15 := (*q)[15] / 258
	if q0 > 127 {
		q0 = 127
	} else if q0 < -128 {
		q0 = -128
	}
	if q1 > 127 {
		q1 = 127
	} else if q1 < -128 {
		q1 = -128
	}
	if q2 > 127 {
		q2 = 127
	} else if q2 < -128 {
		q2 = -128
	}
	if q3 > 127 {
		q3 = 127
	} else if q3 < -128 {
		q3 = -128
	}
	if q4 > 127 {
		q4 = 127
	} else if q4 < -128 {
		q4 = -128
	}
	if q5 > 127 {
		q5 = 127
	} else if q5 < -128 {
		q5 = -128
	}
	if q6 > 127 {
		q6 = 127
	} else if q6 < -128 {
		q6 = -128
	}
	if q7 > 127 {
		q7 = 127
	} else if q7 < -128 {
		q7 = -128
	}
	if q8 > 127 {
		q8 = 127
	} else if q8 < -128 {
		q8 = -128
	}
	if q9 > 127 {
		q9 = 127
	} else if q9 < -128 {
		q9 = -128
	}
	if q10 > 127 {
		q10 = 127
	} else if q10 < -128 {
		q10 = -128
	}
	if q11 > 127 {
		q11 = 127
	} else if q11 < -128 {
		q11 = -128
	}
	if q12 > 127 {
		q12 = 127
	} else if q12 < -128 {
		q12 = -128
	}
	if q13 > 127 {
		q13 = 127
	} else if q13 < -128 {
		q13 = -128
	}
	if q14 > 127 {
		q14 = 127
	} else if q14 < -128 {
		q14 = -128
	}
	if q15 > 127 {
		q15 = 127
	} else if q15 < -128 {
		q15 = -128
	}
	result[0] = int8(q0)
	result[1] = int8(q1)
	result[2] = int8(q2)
	result[3] = int8(q3)
	result[4] = int8(q4)
	result[5] = int8(q5)
	result[6] = int8(q6)
	result[7] = int8(q7)
	result[8] = int8(q8)
	result[9] = int8(q9)
	result[10] = int8(q10)
	result[11] = int8(q11)
	result[12] = int8(q12)
	result[13] = int8(q13)
	result[14] = int8(q14)
	result[15] = int8(q15)
	return result
}

// distanceFromCentroidBytesVec computes distance between int8 query and centroid bytes
func distanceFromCentroidBytesVec(q_i8 *[VectDim]int8, vbytes []byte) int64 {
	var diff [VectDim]int32
	diff[0] = int32((*q_i8)[0]) - int32(int8(vbytes[0]))
	diff[1] = int32((*q_i8)[1]) - int32(int8(vbytes[1]))
	diff[2] = int32((*q_i8)[2]) - int32(int8(vbytes[2]))
	diff[3] = int32((*q_i8)[3]) - int32(int8(vbytes[3]))
	diff[4] = int32((*q_i8)[4]) - int32(int8(vbytes[4]))
	diff[5] = int32((*q_i8)[5]) - int32(int8(vbytes[5]))
	diff[6] = int32((*q_i8)[6]) - int32(int8(vbytes[6]))
	diff[7] = int32((*q_i8)[7]) - int32(int8(vbytes[7]))
	diff[8] = int32((*q_i8)[8]) - int32(int8(vbytes[8]))
	diff[9] = int32((*q_i8)[9]) - int32(int8(vbytes[9]))
	diff[10] = int32((*q_i8)[10]) - int32(int8(vbytes[10]))
	diff[11] = int32((*q_i8)[11]) - int32(int8(vbytes[11]))
	diff[12] = int32((*q_i8)[12]) - int32(int8(vbytes[12]))
	diff[13] = int32((*q_i8)[13]) - int32(int8(vbytes[13]))
	diff[14] = int32((*q_i8)[14]) - int32(int8(vbytes[14]))
	diff[15] = int32((*q_i8)[15]) - int32(int8(vbytes[15]))
	return int64(diff[0]*diff[0]) + int64(diff[1]*diff[1]) + int64(diff[2]*diff[2]) + int64(diff[3]*diff[3]) +
		int64(diff[4]*diff[4]) + int64(diff[5]*diff[5]) + int64(diff[6]*diff[6]) + int64(diff[7]*diff[7]) +
		int64(diff[8]*diff[8]) + int64(diff[9]*diff[9]) + int64(diff[10]*diff[10]) + int64(diff[11]*diff[11]) +
		int64(diff[12]*diff[12]) + int64(diff[13]*diff[13]) + int64(diff[14]*diff[14]) + int64(diff[15]*diff[15])
}

type Scorer struct {
	dataset    *Dataset
	n_clusters uint32
}

func (s *Scorer) Init(ds *Dataset) {
	s.dataset = ds
	s.n_clusters = uint32(len(ds.centroids_mmap) / 16)
}

func (s *Scorer) FindNearestClusters(query *QueryVector, nprobe uint32) [NPROBE]uint32 {
	var result [NPROBE]uint32
	for i := range result {
		result[i] = 0
	}

	if s.n_clusters == 0 || nprobe == 0 {
		return result
	}

	clustersToScan := s.n_clusters
	if clustersToScan > 256 {
		clustersToScan = 256
	}
	nprobeCount := nprobe
	if nprobeCount > s.n_clusters {
		nprobeCount = s.n_clusters
	}

	q_i8 := queryToVec16I8((*[VectDim]int16)(unsafe.Pointer(query)))

	type pair struct {
		dist int64
		idx  uint32
	}
	var best [NPROBE]pair
	for i := range best {
		best[i].dist = math.MaxInt64
		best[i].idx = 0
	}
	bestCount := uint32(0)

	for i := uint32(0); i < clustersToScan; i++ {
		centroidOffset := i * 16
		centroidBytes := s.dataset.centroids_mmap[centroidOffset : centroidOffset+16]
		dist := distanceFromCentroidBytesVec(&q_i8, centroidBytes)

		if bestCount < nprobeCount {
			pos := bestCount
			for pos > 0 && dist < best[pos-1].dist {
				best[pos] = best[pos-1]
				pos--
			}
			best[pos] = pair{dist, i}
			bestCount++
			continue
		}

		if dist >= best[nprobeCount-1].dist {
			continue
		}
		pos := nprobeCount - 1
		for pos > 0 && dist < best[pos-1].dist {
			best[pos] = best[pos-1]
			pos--
		}
		best[pos] = pair{dist, i}
	}

	for k := uint32(0); k < nprobeCount; k++ {
		result[k] = best[k].idx
	}
	return result
}

func (s *Scorer) Score(query *QueryVector) float32 {
	reqNum := runtimeStatsRequests.Add(1)
	sampleStats := (reqNum & 63) == 0

	if s.n_clusters == 0 || len(s.dataset.vectors_mmap) == 0 {
		return 0.0
	}

	clusterIndices := s.FindNearestClusters(query, NPROBE)

	maxVecIdx := uint32(len(s.dataset.vectors_mmap) / VectorBytes)
	var topK TopK
	topK.Init()

	var clusterContrib [NPROBE]uint32
	for i := range clusterContrib {
		clusterContrib[i] = 0
	}

	pass1Budget := uint32(TotalScanBudget * Pass1Percent / 100)
	remainingBudget := pass1Budget
	probesTotal := int(NPROBE)

	qPtr := (*[VectDim]int16)(unsafe.Pointer(query))
	qI8 := queryToVec16I8(qPtr)

	for i := uint32(0); i < uint32(probesTotal); i++ {
		if remainingBudget == 0 {
			break
		}

		clusterID := clusterIndices[i]
		if clusterID >= s.n_clusters {
			continue
		}

		if topK.count >= K {
			centroidOffset := clusterID * 16
			cBytes := s.dataset.centroids_mmap[centroidOffset : centroidOffset+16]
			centroidDist := distanceFromCentroidBytesVec(&qI8, cBytes)
			if centroidDist >= topK.distances[K-1] {
				continue
			}
		}

		range_ := s.dataset.ClusterRange(clusterID)
		if range_.start >= range_.end {
			continue
		}

		start := range_.start
		end := range_.end
		if end > maxVecIdx {
			end = maxVecIdx
		}
		if end <= start {
			continue
		}

		probesLeft := probesTotal - int(i)
		perClusterBudget := remainingBudget / uint32(probesLeft)
		if perClusterBudget == 0 {
			perClusterBudget = 1
		}
		clusterLen := end - start
		scanLen := clusterLen
		if scanLen > perClusterBudget {
			scanLen = perClusterBudget
		}
		scanEnd := start + scanLen

		if sampleStats {
			runtimeStatsClusterScannedVectors.Add(uint64(scanLen))
		}
		remainingBudget -= scanLen

		vecStart := uint64(start) * VectorBytes
		vecEnd := uint64(scanEnd) * VectorBytes
		vecLen := uint64(len(s.dataset.vectors_mmap))
		if vecEnd > vecLen {
			continue
		}

		vecSlice := s.dataset.vectors_mmap[vecStart:vecEnd]
		vecSliceLen := len(vecSlice)
		for j := uint32(0); j < scanLen; j++ {
			vecOffset := int(j) * VectorBytes
			if vecOffset+VectorBytes > vecSliceLen {
				break
			}
			ptr := vecSlice[vecOffset : vecOffset+VectorBytes]
			// Prefetch next iteration
			if int(j)+2 < int(scanLen) {
				pfOffset := (int(j) + 2) * VectorBytes
				if pfOffset+VectorBytes <= vecSliceLen {
					unix.Madvise(vecSlice[pfOffset:pfOffset+VectorBytes], unix.MADV_WILLNEED)
				}
			}
			dist := distanceFromBytes(qPtr, ptr)
			globalIdx := start + j
			if topK.Insert(dist, globalIdx) {
				clusterContrib[i]++
			}
		}
	}

	pass2Budget := uint32(TotalScanBudget) - pass1Budget
	var pass2Clusters [2]uint32
	var pass2Counts [2]uint32
	pass2Clusters[0] = 0
	pass2Clusters[1] = 0
	pass2Counts[0] = 0
	pass2Counts[1] = 0

	for c := uint32(0); c < uint32(probesTotal); c++ {
		if clusterContrib[c] > 0 {
			if clusterContrib[c] >= pass2Counts[0] {
				pass2Counts[1] = pass2Counts[0]
				pass2Clusters[1] = pass2Clusters[0]
				pass2Counts[0] = clusterContrib[c]
				pass2Clusters[0] = c
			} else if clusterContrib[c] >= pass2Counts[1] {
				pass2Counts[1] = clusterContrib[c]
				pass2Clusters[1] = c
			}
		}
	}

	if pass2Counts[0] > 0 {
		totalPass2Contrib := pass2Counts[0] + pass2Counts[1]
		for p := 0; p < 2; p++ {
			if pass2Clusters[p] >= s.n_clusters {
				continue
			}
			probeIdx := pass2Clusters[p]
			if probeIdx >= NPROBE {
				continue
			}
			ci := clusterIndices[probeIdx]
			if ci >= s.n_clusters {
				continue
			}
			range_ := s.dataset.ClusterRange(ci)
			if range_.start >= range_.end {
				continue
			}

			start := range_.start
			end := range_.end
			if end > maxVecIdx {
				end = maxVecIdx
			}
			if end <= start {
				continue
			}

			clusterLen := end - start
			allocBudget := pass2Budget * pass2Counts[p] / totalPass2Contrib
			scanLen := clusterLen
			if scanLen > allocBudget && allocBudget > 0 {
				scanLen = allocBudget
			}
			if scanLen < 1 {
				scanLen = 1
			}
			scanEnd := start + scanLen

			if sampleStats {
				runtimeStatsClusterScannedVectors.Add(uint64(scanLen))
			}

			vecStart := uint64(start) * VectorBytes
			vecEnd := uint64(scanEnd) * VectorBytes
			vecLen := uint64(len(s.dataset.vectors_mmap))
			if vecEnd > vecLen {
				continue
			}

			vecSlice := s.dataset.vectors_mmap[vecStart:vecEnd]
			vecSliceLen := len(vecSlice)
			for j := uint32(0); j < scanLen; j++ {
				vecOffset := int(j) * VectorBytes
				if vecOffset+VectorBytes > vecSliceLen {
					break
				}
				ptr := vecSlice[vecOffset : vecOffset+VectorBytes]
				// Prefetch next iteration
				if int(j)+2 < int(scanLen) {
					pfOffset := (int(j) + 2) * VectorBytes
					if pfOffset+VectorBytes <= vecSliceLen {
						unix.Madvise(vecSlice[pfOffset:pfOffset+VectorBytes], unix.MADV_WILLNEED)
					}
				}
				dist := distanceFromBytes(qPtr, ptr)
				topK.InsertUnique(dist, start+j)
			}
		}
	}

	if topK.count < K {
		if sampleStats {
			runtimeStatsFallbackHits.Add(1)
			runtimeStatsFallbackScannedVectors.Add(uint64(maxVecIdx))
		}
		vecLen := uint64(len(s.dataset.vectors_mmap))
		for idx := uint32(0); idx < maxVecIdx; idx++ {
			vecOffset := uint64(idx) * VectorBytes
			if vecOffset+VectorBytes > vecLen {
				break
			}
			ptr := s.dataset.vectors_mmap[vecOffset : vecOffset+VectorBytes]
			dist := distanceFromBytes(qPtr, ptr)
			topK.InsertUnique(dist, idx)
		}
	}

	if topK.count == 0 {
		return 0.0
	}

	fraudCount := uint32(0)
	for i := uint32(0); i < topK.count; i++ {
		if s.dataset.LabelAt(topK.indices[i]) == 1 {
			fraudCount++
		}
	}

	if topK.count == K && fraudCount > 0 && fraudCount < K {
		return s.refineClusterScore(query, maxVecIdx, &clusterIndices)
	}

	return float32(fraudCount) / float32(topK.count)
}

func (s *Scorer) refineClusterScore(query *QueryVector, maxVecIdx uint32, clusterIndices *[NPROBE]uint32) float32 {
	var topK TopK
	topK.Init()
	remainingBudget := uint32(3000000)

	qPtr := (*[VectDim]int16)(unsafe.Pointer(query))

	for probeIdx := uint32(0); probeIdx < NPROBE; probeIdx++ {
		if remainingBudget == 0 {
			break
		}
		clusterID := clusterIndices[probeIdx]
		if clusterID >= s.n_clusters {
			continue
		}
		range_ := s.dataset.ClusterRange(clusterID)
		if range_.start >= range_.end {
			continue
		}

		end := range_.end
		if end > maxVecIdx {
			end = maxVecIdx
		}
		clusterLen := end - range_.start
		probesLeft := NPROBE - probeIdx
		scanLen := clusterLen
		if scanLen > remainingBudget/probesLeft {
			scanLen = remainingBudget / probesLeft
		}
		if scanLen < 1 {
			scanLen = 1
		}
		remainingBudget -= scanLen
		scanEnd := range_.start + scanLen

		vecStart := uint64(range_.start) * VectorBytes
		vecEnd := uint64(scanEnd) * VectorBytes
		vecLen := uint64(len(s.dataset.vectors_mmap))
		if vecEnd > vecLen {
			continue
		}

		vecSlice := s.dataset.vectors_mmap[vecStart:vecEnd]
		vecSliceLen := len(vecSlice)
		for idx := range_.start; idx < scanEnd; idx++ {
			vecOffset := int(idx - range_.start) * VectorBytes
			if vecOffset+VectorBytes > vecSliceLen {
				break
			}
			ptr := vecSlice[vecOffset : vecOffset+VectorBytes]
			dist := distanceFromBytes(qPtr, ptr)
			topK.InsertUnique(dist, idx)
		}
	}

	if topK.count == 0 {
		return 0.0
	}

	fraudCount := uint32(0)
	for i := uint32(0); i < topK.count; i++ {
		if s.dataset.LabelAt(topK.indices[i]) == 1 {
			fraudCount++
		}
	}
	return float32(fraudCount) / float32(topK.count)
}

// Global stats
var runtimeStatsRequests           atomic.Uint64
var runtimeStatsFallbackHits       atomic.Uint64
var runtimeStatsFallbackScannedVectors atomic.Uint64
var runtimeStatsClusterScannedVectors atomic.Uint64