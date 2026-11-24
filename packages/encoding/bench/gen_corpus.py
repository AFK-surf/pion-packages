#!/usr/bin/env python3
"""Generate deterministic 1 MB HTML corpora for packages/encoding benchmarks:
- html_utf8.bin: ~1 MB mixed ASCII + UTF-8 HTML document (Scenario A)
- html_gb18030.bin: ~1 MB mixed ASCII + Chinese GB18030 HTML document (Scenario B1)
- html_sjis.bin: ~1 MB mixed ASCII + Japanese Shift_JIS HTML document (Scenario B2)
"""
import sys
from pathlib import Path

def repeat_to_size(chunk: bytes, target: int) -> bytes:
    reps = (target + len(chunk) - 1) // len(chunk)
    return (chunk * reps)[:target]

def main():
    out_dir = Path(sys.argv[1])
    out_dir.mkdir(parents=True, exist_ok=True)
    target = 1024 * 1024  # 1 MiB each

    utf8_block = (
        '<article class="post" data-id="42" lang="mul">'
        '<h2>WHATWG Encoding Standard — Café &amp; 日本語 &amp; 中文 &amp; 한국어 🚀</h2>'
        '<p>Fast web browsers sniff BOMs, resolve charset labels, and stream HTML bytes into UTF-8. '
        'Résumé, naïve, über, façade, Ελληνικά, Кириллица, العربية, עברית. '
        '现代浏览器字符集解码器需要高吞吐的 ASCII 快路径与严格的边界处理。</p>'
        '<ul><li><a href="https://encoding.spec.whatwg.org/">Spec</a></li>'
        '<li><code>TextDecoder("utf-8", { fatal: false })</code></li></ul>'
        '</article>\n'
    ).encode("utf-8")

    gb_block = (
        '<article class="news" data-region="cn">'
        '<h2>浏览器字符集解码与中文网页渲染性能基准测试</h2>'
        '<p>在真实中文互联网环境中，大量历史政企门户、电子政务系统、邮件归档与传统论坛仍广泛使用 '
        'GBK 与 GB18030 编码。高效解码器应当对连续的 HTML 标签与 ASCII 属性走批量快路径，'
        '同时对常用 GB2312 一二级汉字提供 O(1) 查表映射，确保吞吐量与内存占用均达到生产级水准。'
        '价格：€128.50，编号：No.2026-11-24。</p>'
        '<div class="meta"><span>作者：前端架构组</span><span>分类：渲染引擎</span></div>'
        '</article>\n'
    ).encode("gb18030")

    sjis_block = (
        '<article class="entry" data-region="jp">'
        '<h2>日本語ウェブページとShift_JIS文字コードの高速デコード検証</h2>'
        '<p>日本のレガシーウェブサイトやメールアーカイブでは、現在でも Shift_JIS（Windows-31J）が'
        '広く利用されています。ひらがな・カタカナ・JIS第一水準漢字・半角ｶﾀｶﾅ（ｱｲｳｴｵ）と '
        'HTML タグが混在する文書を高速かつ仕様通りにデコードすることが重要です。'
        '更新日：2026年11月24日、担当：ブラウザ開発チーム。</p>'
        '<div class="tags"><a href="/jp/html">HTML5</a><a href="/jp/dom">DOM</a></div>'
        '</article>\n'
    ).encode("cp932")

    # Trim on clean character boundary by repeating whole blocks up to >= 1 MiB
    def build_exact(block: bytes) -> bytes:
        reps = max(1, target // len(block))
        return block * reps

    f_utf8 = build_exact(utf8_block)
    f_gb = build_exact(gb_block)
    f_sjis = build_exact(sjis_block)

    (out_dir / "html_utf8.bin").write_bytes(f_utf8)
    (out_dir / "html_gb18030.bin").write_bytes(f_gb)
    (out_dir / "html_sjis.bin").write_bytes(f_sjis)
    print(f"{len(f_utf8)} {len(f_gb)} {len(f_sjis)}")

if __name__ == "__main__":
    main()
