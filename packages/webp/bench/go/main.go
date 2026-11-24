package main

import (
	"bytes"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"

	"golang.org/x/image/webp"
)

func savePNG(path string, img *image.NRGBA) {
	f, err := os.Create(path)
	if err != nil {
		panic(err)
	}
	defer f.Close()
	if err := png.Encode(f, img); err != nil {
		panic(err)
	}
}

func runCwebp(inPNG, outWebP string, args ...string) {
	fullArgs := append(args, inPNG, "-o", outWebP)
	cmd := exec.Command("cwebp", fullArgs...)
	if out, err := cmd.CombinedOutput(); err != nil {
		panic(fmt.Sprintf("cwebp failed: %v\n%s", err, string(out)))
	}
}

// Generate deterministic 512x512 rich photographic + UI-style corpora:
// 1. vp8l_512x512.webp (lossless with alpha, triggers Predictor, CrossColor, SubtractGreen, LZ77, ColorCache, Meta-Huffman)
// 2. vp8_512x512.webp (lossy q=80, triggers I16x16, I4x4, normal loop filter)
// 3. vp8x_alph_512x512.webp (VP8 lossy + VP8L-compressed filtered ALPH)
// 4. alpha_512.rgba (raw RGBA8888 for lossless encode benchmarks)
func generateCorpora(dir string) {
	const w, h = 512, 512
	opaque := image.NewNRGBA(image.Rect(0, 0, w, h))
	alphaImg := image.NewNRGBA(image.Rect(0, 0, w, h))

	for y := 0; y < h; y++ {
		fy := float64(y) / float64(h)
		for x := 0; x < w; x++ {
			fx := float64(x) / float64(w)
			// Rich smooth + sharp edges + checkerboard + sine texture
			r := int(127.5 + 80.0*math.Sin(fx*18.0+fy*7.0) + 40.0*math.Cos(fx*43.0-fy*29.0))
			g := int(127.5 + 70.0*math.Cos(fy*15.0-fx*9.0) + 45.0*math.Sin((fx+fy)*31.0))
			b := int(127.5 + 85.0*math.Sin(fx*11.0-fy*19.0) + 35.0*math.Cos(fx*23.0+fy*37.0))
			if (x/32+y/32)%2 == 0 && (x%32 < 4 || y%32 < 4) {
				// Crisp UI grid lines
				r, g, b = 240, 244, 248
			}
			if x >= 128 && x < 384 && y >= 128 && y < 384 {
				dx := float64(x-256) / 128.0
				dy := float64(y-256) / 128.0
				if dx*dx+dy*dy < 0.65 {
					r = (r + 220) / 2
					g = (g + 90) / 2
					b = (b + 40) / 2
				}
			}
			if r < 0 {
				r = 0
			} else if r > 255 {
				r = 255
			}
			if g < 0 {
				g = 0
			} else if g > 255 {
				g = 255
			}
			if b < 0 {
				b = 0
			} else if b > 255 {
				b = 255
			}
			a := uint8(255)
			dx := float64(x-256) / 256.0
			dy := float64(y-256) / 256.0
			dist := math.Sqrt(dx*dx + dy*dy)
			if dist > 0.7 {
				av := int(255.0 * (1.0 - (dist-0.7)/0.5))
				if av < 0 {
					av = 0
				}
				a = uint8(av)
			}
			opaque.SetNRGBA(x, y, color.NRGBA{uint8(r), uint8(g), uint8(b), 255})
			alphaImg.SetNRGBA(x, y, color.NRGBA{uint8(r), uint8(g), uint8(b), a})
		}
	}

	opaquePNG := filepath.Join(dir, "opaque_512.png")
	alphaPNG := filepath.Join(dir, "alpha_512.png")
	savePNG(opaquePNG, opaque)
	savePNG(alphaPNG, alphaImg)
	if err := os.WriteFile(filepath.Join(dir, "alpha_512.rgba"), alphaImg.Pix, 0644); err != nil {
		panic(err)
	}

	runCwebp(alphaPNG, filepath.Join(dir, "vp8l_512x512.webp"), "-lossless", "-z", "6", "-quiet")
	runCwebp(opaquePNG, filepath.Join(dir, "vp8_512x512.webp"), "-q", "80", "-quiet")
	runCwebp(alphaPNG, filepath.Join(dir, "vp8x_alph_512x512.webp"), "-q", "80", "-alpha_q", "100", "-quiet")
}

func decodeToRGBA(data []byte) ([]byte, error) {
	img, err := webp.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	out := make([]byte, w*h*4)
	switch m := img.(type) {
	case *image.NRGBA:
		for y := 0; y < h; y++ {
			copy(out[y*w*4:(y+1)*w*4], m.Pix[y*m.Stride:y*m.Stride+w*4])
		}
	case *image.YCbCr:
		idx := 0
		for y := 0; y < h; y++ {
			for x := 0; x < w; x++ {
				yi := m.YOffset(x, y)
				ci := m.COffset(x, y)
				r, g, bl := color.YCbCrToRGB(m.Y[yi], m.Cb[ci], m.Cr[ci])
				out[idx+0] = r
				out[idx+1] = g
				out[idx+2] = bl
				out[idx+3] = 255
				idx += 4
			}
		}
	case *image.NYCbCrA:
		idx := 0
		for y := 0; y < h; y++ {
			for x := 0; x < w; x++ {
				yi := m.YOffset(x, y)
				ci := m.COffset(x, y)
				ai := m.AOffset(x, y)
				r, g, bl := color.YCbCrToRGB(m.Y[yi], m.Cb[ci], m.Cr[ci])
				out[idx+0] = r
				out[idx+1] = g
				out[idx+2] = bl
				out[idx+3] = m.A[ai]
				idx += 4
			}
		}
	default:
		return nil, fmt.Errorf("unexpected image type %T", img)
	}
	return out, nil
}

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintf(os.Stderr, "usage:\n  go_webp_bench gen <dir>\n  go_webp_bench decode <webp_file> <iters>\n  go_webp_bench verify-rgba <webp_file> <rgba_file> <exact|nonexact>\n")
		os.Exit(1)
	}
	if os.Args[1] == "gen" {
		generateCorpora(os.Args[2])
		return
	}
	if os.Args[1] == "decode" {
		if len(os.Args) < 4 {
			fmt.Fprintf(os.Stderr, "usage: go_webp_bench decode <webp_file> <iters>\n")
			os.Exit(1)
		}
		data, err := os.ReadFile(os.Args[2])
		if err != nil {
			fmt.Fprintf(os.Stderr, "read error: %v\n", err)
			os.Exit(1)
		}
		iters, err := strconv.Atoi(os.Args[3])
		if err != nil || iters <= 0 {
			fmt.Fprintf(os.Stderr, "invalid iters: %s\n", os.Args[3])
			os.Exit(1)
		}
		var last []byte
		for i := 0; i < iters; i++ {
			last, err = decodeToRGBA(data)
			if err != nil {
				fmt.Fprintf(os.Stderr, "decode error: %v\n", err)
				os.Exit(1)
			}
		}
		os.Stdout.Write(last)
		return
	}
	if os.Args[1] == "verify-rgba" {
		if len(os.Args) < 5 {
			fmt.Fprintf(os.Stderr, "usage: go_webp_bench verify-rgba <webp_file> <rgba_file> <exact|nonexact>\n")
			os.Exit(1)
		}
		webpData, err := os.ReadFile(os.Args[2])
		if err != nil {
			fmt.Fprintf(os.Stderr, "read webp error: %v\n", err)
			os.Exit(1)
		}
		wantRGBA, err := os.ReadFile(os.Args[3])
		if err != nil {
			fmt.Fprintf(os.Stderr, "read rgba error: %v\n", err)
			os.Exit(1)
		}
		exact := os.Args[4] == "exact"
		gotRGBA, err := decodeToRGBA(webpData)
		if err != nil {
			fmt.Fprintf(os.Stderr, "go x/image/webp decode failed on %s: %v\n", os.Args[2], err)
			os.Exit(1)
		}
		if len(gotRGBA) != len(wantRGBA) {
			fmt.Fprintf(os.Stderr, "length mismatch on %s: got %d, want %d\n", os.Args[2], len(gotRGBA), len(wantRGBA))
			os.Exit(1)
		}
		if exact {
			if !bytes.Equal(gotRGBA, wantRGBA) {
				for i := 0; i < len(wantRGBA); i++ {
					if gotRGBA[i] != wantRGBA[i] {
						fmt.Fprintf(os.Stderr, "exact mismatch on %s at byte %d: got %d, want %d\n", os.Args[2], i, gotRGBA[i], wantRGBA[i])
						os.Exit(1)
					}
				}
			}
		} else {
			for p := 0; p < len(wantRGBA); p += 4 {
				if gotRGBA[p+3] != wantRGBA[p+3] {
					fmt.Fprintf(os.Stderr, "alpha mismatch on %s at pixel %d: got %d, want %d\n", os.Args[2], p/4, gotRGBA[p+3], wantRGBA[p+3])
					os.Exit(1)
				}
				if wantRGBA[p+3] != 0 {
					if gotRGBA[p] != wantRGBA[p] || gotRGBA[p+1] != wantRGBA[p+1] || gotRGBA[p+2] != wantRGBA[p+2] {
						fmt.Fprintf(os.Stderr, "rgb mismatch on %s at pixel %d\n", os.Args[2], p/4)
						os.Exit(1)
					}
				}
			}
		}
		fmt.Printf("OK %s (%d webp bytes, %d rgba bytes, exact=%v)\n", filepath.Base(os.Args[2]), len(webpData), len(gotRGBA), exact)
		return
	}
	fmt.Fprintf(os.Stderr, "unknown command: %s\n", os.Args[1])
	os.Exit(1)
}
