package main

import (
	"archive/tar"
	"bytes"
	"fmt"
	"io"
	"os"
	"strconv"
	"time"
)

type entry struct {
	hdr  tar.Header
	data []byte
}

func makePayload(idx, size int) []byte {
	out := make([]byte, size)
	s := (idx*31 + 17) & 0xFF
	for i := 0; i < size; i++ {
		out[i] = byte(s)
		s = (s*73 + 19) & 0xFF
	}
	return out
}

func buildEntries(count int) []entry {
	out := make([]entry, 0, count)
	for i := 0; i < count; i++ {
		mod := i % 20
		if mod < 12 {
			if mod == 11 {
				out = append(out, entry{
					hdr: tar.Header{
						Typeflag: tar.TypeDir,
						Name:     "pkg/mod_" + strconv.Itoa(i/20) + "/dir_" + strconv.Itoa(i) + "/",
						Mode:     0755,
						Uid:      1000,
						Gid:      1000,
						Uname:    "builder",
						Gname:    "staff",
						ModTime:  time.Unix(1700000000+int64(i), 0),
					},
				})
			} else if mod == 10 {
				out = append(out, entry{
					hdr: tar.Header{
						Typeflag: tar.TypeSymlink,
						Name:     "pkg/mod_" + strconv.Itoa(i/20) + "/link_" + strconv.Itoa(i),
						Linkname: "file_" + strconv.Itoa(i-1) + ".dat",
						Mode:     0777,
						Uid:      1000,
						Gid:      1000,
						Uname:    "builder",
						Gname:    "staff",
						ModTime:  time.Unix(1700000000+int64(i), 0),
					},
				})
			} else {
				sz := 256 + ((i * 397) % 3072)
				data := makePayload(i, sz)
				out = append(out, entry{
					hdr: tar.Header{
						Typeflag: tar.TypeReg,
						Name:     "pkg/mod_" + strconv.Itoa(i/20) + "/src/file_" + strconv.Itoa(i) + ".dat",
						Size:     int64(sz),
						Mode:     0644,
						Uid:      1000,
						Gid:      1000,
						Uname:    "builder",
						Gname:    "staff",
						ModTime:  time.Unix(1700000000+int64(i), 0),
					},
					data: data,
				})
			}
		} else if mod < 17 {
			sz := 512 + ((i * 613) % 4096)
			data := makePayload(i, sz)
			longName := "workspace/services/telemetry_cluster_v4/shards/region_ap_northeast_1/partition_" +
				strconv.Itoa(i/10) +
				"/sub_component_alpha_beta_gamma/artifact_item_" +
				strconv.Itoa(i) +
				".bin"
			out = append(out, entry{
				hdr: tar.Header{
					Typeflag: tar.TypeReg,
					Name:     longName,
					Size:     int64(sz),
					Mode:     0644,
					Uid:      2500000 + i,
					Gid:      1000,
					Uname:    "pax_user",
					Gname:    "pax_group",
					ModTime:  time.Unix(1700000000+int64(i), 0),
					Format:   tar.FormatPAX,
				},
				data: data,
			})
		} else {
			sz := 512 + ((i * 521) % 3584)
			data := makePayload(i, sz)
			gnuName := "gnu_archive/deep_hierarchy/segment_0001/segment_0002/segment_0003/segment_0004/segment_0005/long_gnu_entry_" +
				strconv.Itoa(i) +
				".blob"
			out = append(out, entry{
				hdr: tar.Header{
					Typeflag: tar.TypeReg,
					Name:     gnuName,
					Size:     int64(sz),
					Mode:     0644,
					Uid:      1000,
					Gid:      1000,
					Uname:    "gnu_user",
					Gname:    "gnu_group",
					ModTime:  time.Unix(1700000000+int64(i), 0),
					Format:   tar.FormatGNU,
				},
				data: data,
			})
		}
	}
	return out
}

func main() {
	const count = 2000
	const rounds = 20
	entries := buildEntries(count)
	var totalArchiveBytes int64
	var lastArchive []byte

	for r := 0; r < rounds; r++ {
		var buf bytes.Buffer
		buf.Grow(6 * 1024 * 1024)
		tw := tar.NewWriter(&buf)
		for i := range entries {
			if err := tw.WriteHeader(&entries[i].hdr); err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
			if len(entries[i].data) > 0 {
				if _, err := tw.Write(entries[i].data); err != nil {
					fmt.Fprintln(os.Stderr, err)
					os.Exit(1)
				}
			}
		}
		if err := tw.Close(); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		b := buf.Bytes()
		totalArchiveBytes += int64(len(b))
		lastArchive = b
	}

	// Verify encoded archive once
	tr := tar.NewReader(bytes.NewReader(lastArchive))
	var verifiedEntries int64
	var verifiedPayload int64
	var checksum uint64 = 14695981039346656037
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
		verifiedEntries++
		for _, c := range []byte(hdr.Name) {
			checksum = (checksum ^ uint64(c)) * 1099511628211
		}
		if hdr.Size > 0 {
			body, err := io.ReadAll(tr)
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(3)
			}
			verifiedPayload += int64(len(body))
			checksum = (checksum ^ uint64(body[0])) * 1099511628211
			checksum = (checksum ^ uint64(body[len(body)-1])) * 1099511628211
		}
	}

	blockAligned := 0
	if totalArchiveBytes%512 == 0 {
		blockAligned = 1
	}
	fmt.Printf("rounds=%d\n", rounds)
	fmt.Printf("entries=%d\n", verifiedEntries)
	fmt.Printf("payload_bytes=%d\n", verifiedPayload)
	fmt.Printf("block_aligned=%d\n", blockAligned)
	fmt.Printf("checksum=%d\n", checksum)
}
