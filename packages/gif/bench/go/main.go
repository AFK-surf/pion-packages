package main

import (
	"bytes"
	"fmt"
	"image"
	"image/color"
	"image/gif"
	"os"
	"path/filepath"
	"strconv"
)

func buildPalette256() color.Palette {
	p := make(color.Palette, 256)
	for i := 0; i < 256; i++ {
		r := uint8((i * 73 + 17) & 0xFF)
		g := uint8((i * 151 + 53) & 0xFF)
		b := uint8((i * 211 + 97) & 0xFF)
		p[i] = color.RGBA{R: r, G: g, B: b, A: 255}
	}
	// Index 0 is a distinct dark tone; index 255 is transparent in animated frames
	p[0] = color.RGBA{R: 32, G: 24, B: 18, A: 255}
	return p
}

func generateCorpora(outDir string) error {
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return err
	}
	pal := buildPalette256()

	// 1. Realistic 512x512 static texture GIF (wood-grain / crate-like pattern with rich LZW dictionary)
	{
		const w, h = 512, 512
		img := image.NewPaletted(image.Rect(0, 0, w, h), pal)
		for y := 0; y < h; y++ {
			for x := 0; x < w; x++ {
				border := x < 24 || x >= w-24 || y < 24 || y >= h-24
				diag := (x-y >= -18 && x-y <= 18) || (x+y >= w-18 && x+y <= w+18)
				plank := (y / 32) % 2
				grain := ((x*3 + (y/4)*7 + (x^y)/8) / 5) & 31
				var idx uint8
				if border {
					idx = uint8(16 + (grain & 15))
				} else if diag {
					idx = uint8(64 + (grain & 15))
				} else {
					idx = uint8(128 + plank*32 + grain)
				}
				img.SetColorIndex(x, y, idx)
			}
		}
		var buf bytes.Buffer
		if err := gif.Encode(&buf, img, &gif.Options{NumColors: 256}); err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(outDir, "static_512x512.gif"), buf.Bytes(), 0o644); err != nil {
			return err
		}
	}

	// 2. Realistic 256x256 24-frame animated GIF with sub-rects, transparency, and all 4 disposal methods
	{
		const w, h, nframes = 256, 256, 24
		animPal := make(color.Palette, 256)
		copy(animPal, pal)
		animPal[255] = color.RGBA{R: 0, G: 0, B: 0, A: 0} // transparent index 255

		g := &gif.GIF{
			LoopCount: 0,
			Config: image.Config{
				ColorModel: animPal,
				Width:      w,
				Height:     h,
			},
		}

		for f := 0; f < nframes; f++ {
			var rect image.Rectangle
			var disp byte
			if f == 0 {
				rect = image.Rect(0, 0, w, h)
				disp = gif.DisposalNone
			} else {
				// Moving 128x128 sprite sub-rect with mixed disposal methods
				ox := (f * 9) % (w - 128)
				oy := (f * 7) % (h - 128)
				rect = image.Rect(ox, oy, ox+128, oy+128)
				switch f % 4 {
				case 0:
					disp = gif.DisposalNone
				case 1:
					disp = gif.DisposalBackground
				case 2:
					disp = gif.DisposalPrevious
				default:
					disp = 0 // Unspecified
				}
			}
			frame := image.NewPaletted(rect, animPal)
			for y := rect.Min.Y; y < rect.Max.Y; y++ {
				for x := rect.Min.X; x < rect.Max.X; x++ {
					if f == 0 {
						idx := uint8(((x / 8) + (y / 8) + ((x ^ y) / 16)) & 254)
						frame.SetColorIndex(x, y, idx)
					} else {
						dx := x - (rect.Min.X + 64)
						dy := y - (rect.Min.Y + 64)
						if dx*dx+dy*dy > 58*58 {
							frame.SetColorIndex(x, y, 255) // transparent outside circle
						} else {
							idx := uint8((f*11 + (x/4) + (y/4)) % 254)
							frame.SetColorIndex(x, y, idx)
						}
					}
				}
			}
			g.Image = append(g.Image, frame)
			g.Delay = append(g.Delay, 4)
			g.Disposal = append(g.Disposal, disp)
		}

		var buf bytes.Buffer
		if err := gif.EncodeAll(&buf, g); err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(outDir, "anim_256x256_24f.gif"), buf.Bytes(), 0o644); err != nil {
			return err
		}
	}
	return nil
}

// Composite decoded Go gif.GIF into full-canvas RGBA8888 frames matching GIF89a / browser semantics.
func compositeGoGif(g *gif.GIF) [][]byte {
	cw := g.Config.Width
	ch := g.Config.Height
	canvasBytes := cw * ch * 4
	canvas := make([]byte, canvasBytes)
	out := make([][]byte, len(g.Image))

	for fi, palImg := range g.Image {
		b := palImg.Bounds()
		x0 := b.Min.X
		y0 := b.Min.Y
		x1 := b.Max.X
		y1 := b.Max.Y
		if x0 < 0 {
			x0 = 0
		}
		if y0 < 0 {
			y0 = 0
		}
		if x1 > cw {
			x1 = cw
		}
		if y1 > ch {
			y1 = ch
		}

		disp := byte(0)
		if fi < len(g.Disposal) {
			disp = g.Disposal[fi]
		}

		var saved []byte
		if disp == gif.DisposalPrevious && x1 > x0 && y1 > y0 {
			rowBytes := (x1 - x0) * 4
			saved = make([]byte, rowBytes*(y1-y0))
			for y := y0; y < y1; y++ {
				srcOff := (y*cw + x0) * 4
				copy(saved[(y-y0)*rowBytes:(y-y0+1)*rowBytes], canvas[srcOff:srcOff+rowBytes])
			}
		}

		// Build 256-entry RGBA palette for this frame
		var palRGBA [256][4]byte
		for idx, c := range palImg.Palette {
			r, gr, bl, a := c.RGBA()
			palRGBA[idx][0] = byte(r >> 8)
			palRGBA[idx][1] = byte(gr >> 8)
			palRGBA[idx][2] = byte(bl >> 8)
			palRGBA[idx][3] = byte(a >> 8)
		}

		for y := y0; y < y1; y++ {
			srcRow := (y - b.Min.Y) * palImg.Stride
			dstOff := (y*cw + x0) * 4
			for x := x0; x < x1; x++ {
				ci := palImg.Pix[srcRow+(x-b.Min.X)]
				rgba := palRGBA[ci]
				if rgba[3] != 0 {
					canvas[dstOff] = rgba[0]
					canvas[dstOff+1] = rgba[1]
					canvas[dstOff+2] = rgba[2]
					canvas[dstOff+3] = 255
				}
				dstOff += 4
			}
		}

		snap := make([]byte, canvasBytes)
		copy(snap, canvas)
		out[fi] = snap

		if disp == gif.DisposalBackground && x1 > x0 && y1 > y0 {
			rowBytes := (x1 - x0) * 4
			for y := y0; y < y1; y++ {
				dstOff := (y*cw + x0) * 4
				clear(canvas[dstOff : dstOff+rowBytes])
			}
		} else if disp == gif.DisposalPrevious && len(saved) > 0 {
			rowBytes := (x1 - x0) * 4
			for y := y0; y < y1; y++ {
				dstOff := (y*cw + x0) * 4
				copy(canvas[dstOff:dstOff+rowBytes], saved[(y-y0)*rowBytes:(y-y0+1)*rowBytes])
			}
		}
	}
	return out
}

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: go_gif_bench gen <out_dir> | decode_all <gif_file> <iters> | decode_first <gif_file> <iters>")
		os.Exit(1)
	}
	mode := os.Args[1]
	if mode == "gen" {
		if err := generateCorpora(os.Args[2]); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	if len(os.Args) < 4 {
		fmt.Fprintln(os.Stderr, "missing <iters>")
		os.Exit(1)
	}
	data, err := os.ReadFile(os.Args[2])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	iters, err := strconv.Atoi(os.Args[3])
	if err != nil || iters < 1 {
		fmt.Fprintln(os.Stderr, "invalid iters")
		os.Exit(1)
	}

	if mode == "decode_first" {
		var lastRGBA []byte
		for i := 0; i < iters; i++ {
			img, err := gif.Decode(bytes.NewReader(data))
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
			b := img.Bounds()
			cw, ch := b.Dx(), b.Dy()
			palImg := img.(*image.Paletted)
			var palRGBA [256][4]byte
			for idx, c := range palImg.Palette {
				r, gr, bl, a := c.RGBA()
				palRGBA[idx][0] = byte(r >> 8)
				palRGBA[idx][1] = byte(gr >> 8)
				palRGBA[idx][2] = byte(bl >> 8)
				palRGBA[idx][3] = byte(a >> 8)
			}
			rgba := make([]byte, cw*ch*4)
			di := 0
			for y := 0; y < ch; y++ {
				row := y * palImg.Stride
				for x := 0; x < cw; x++ {
					c := palRGBA[palImg.Pix[row+x]]
					if c[3] != 0 {
						rgba[di] = c[0]
						rgba[di+1] = c[1]
						rgba[di+2] = c[2]
						rgba[di+3] = 255
					}
					di += 4
				}
			}
			lastRGBA = rgba
		}
		_, _ = os.Stdout.Write(lastRGBA)
		return
	}

	if mode == "decode_all" {
		var lastFrames [][]byte
		for i := 0; i < iters; i++ {
			g, err := gif.DecodeAll(bytes.NewReader(data))
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
			lastFrames = compositeGoGif(g)
		}
		for _, f := range lastFrames {
			_, _ = os.Stdout.Write(f)
		}
		return
	}

	fmt.Fprintln(os.Stderr, "unknown mode:", mode)
	os.Exit(1)
}
