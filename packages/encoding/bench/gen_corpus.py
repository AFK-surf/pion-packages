#!/usr/bin/env python3
"""Generate deterministic ~1 MiB HTML corpora for packages/encoding benchmarks:
Decode:
- html_utf8.bin:    ~1 MiB mixed ASCII + UTF-8 HTML document (Scenario A)
- html_gb18030.bin: ~1 MiB mixed ASCII + Chinese GB18030 HTML document (Scenario B1)
- html_sjis.bin:    ~1 MiB mixed ASCII + Japanese Shift_JIS HTML document (Scenario B2)
Encode (UTF-8 inputs encoded into legacy CJK encodings with HTML NCR fallback):
- enc_big5.txt:     ~1 MiB mixed ASCII + Traditional Chinese UTF-8 HTML
- enc_gb18030.txt:  ~1 MiB mixed ASCII + Simplified Chinese UTF-8 HTML
- enc_sjis.txt:     ~1 MiB mixed ASCII + Japanese UTF-8 HTML
- enc_euckr.txt:    ~1 MiB mixed ASCII + Korean UTF-8 HTML
"""
import sys
from pathlib import Path


def build_exact(block: bytes, target: int) -> bytes:
    reps = max(1, target // len(block))
    return block * reps


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

    gb_text = (
        '<article class="news" data-region="cn">'
        '<h2>浏览器字符集解码与中文网页渲染性能基准测试</h2>'
        '<p>在真实中文互联网环境中，大量历史政企门户、电子政务系统、邮件归档与传统论坛仍广泛使用 '
        'GBK 与 GB18030 编码。高效解码器应当对连续的 HTML 标签与 ASCII 属性走批量快路径，'
        '同时对常用 GB2312 一二级汉字提供 O(1) 查表映射，确保吞吐量与内存占用均达到生产级水准。'
        '价格：€128.50，编号：No.2026-11-24。</p>'
        '<div class="meta"><span>作者：前端架构组</span><span>分类：渲染引擎</span></div>'
        '</article>\n'
    )

    sjis_text = (
        '<article class="entry" data-region="jp">'
        '<h2>日本語ウェブページとShift_JIS文字コードの高速デコード検証</h2>'
        '<p>日本のレガシーウェブサイトやメールアーカイブでは、現在でも Shift_JIS（Windows-31J）が'
        '広く利用されています。ひらがな・カタカナ・JIS第一水準漢字・半角ｶﾀｶﾅ（ｱｲｳｴｵ）と '
        'HTML タグが混在する文書を高速かつ仕様通りにデコードすることが重要です。'
        '更新日：2026年11月24日、担当：ブラウザ開発チーム。</p>'
        '<div class="tags"><a href="/jp/html">HTML5</a><a href="/jp/dom">DOM</a></div>'
        '</article>\n'
    )

    big5_text = (
        '<article class="post" data-region="tw">'
        '<h2>繁體中文網頁表單提交與 Big5 編碼器高效能基準測試</h2>'
        '<p>在傳統繁體中文網站與歷史表單系統中，瀏覽器需要將使用者輸入的 UTF-8 文字快速編碼為 Big5，'
        '並對無法直接映射的字元（如 Café 與 🚀）依照 WHATWG 規範輸出十進位字元參照。'
        '透過按碼點排序的不可變靜態反查表與二分搜尋，單次查詢從線性掃描降至 O(log N) 比較。</p>'
        '<div class="meta"><span>團隊：瀏覽器引擎組</span><span>日期：2026-11-24</span></div>'
        '</article>\n'
    )

    euckr_text = (
        '<article class="post" data-region="kr">'
        '<h2>한국어 웹 페이지 및 EUC-KR 인코더 성능 벤치마크 테스트</h2>'
        '<p>레거시 한국어 웹 사이트와 이메일 아카이브에서는 완성형 한글(KS X 1001)과 확장 완성형(CP949) '
        '및 한자(漢字, 韓國, 性能, 檢證)를 EUC-KR로 인코딩해야 합니다. '
        '정렬된 불변 테이블과 이진 탐색으로 최악의 입력에서도 안정적인 처리량을 보장합니다.</p>'
        '<div class="meta"><span>작성: 브라우저 팀</span><span>날짜: 2026-11-24</span></div>'
        '</article>\n'
    )

    f_utf8 = build_exact(utf8_block, target)
    f_gb = build_exact(gb_text.encode("gb18030"), target)
    f_sjis = build_exact(sjis_text.encode("cp932"), target)
    f_enc_big5 = build_exact(big5_text.encode("utf-8"), target)
    f_enc_gb = build_exact(gb_text.encode("utf-8"), target)
    f_enc_sjis = build_exact(sjis_text.encode("utf-8"), target)
    f_enc_euckr = build_exact(euckr_text.encode("utf-8"), target)

    (out_dir / "html_utf8.bin").write_bytes(f_utf8)
    (out_dir / "html_gb18030.bin").write_bytes(f_gb)
    (out_dir / "html_sjis.bin").write_bytes(f_sjis)
    (out_dir / "enc_big5.txt").write_bytes(f_enc_big5)
    (out_dir / "enc_gb18030.txt").write_bytes(f_enc_gb)
    (out_dir / "enc_sjis.txt").write_bytes(f_enc_sjis)
    (out_dir / "enc_euckr.txt").write_bytes(f_enc_euckr)

    print(
        f"{len(f_utf8)} {len(f_gb)} {len(f_sjis)} "
        f"{len(f_enc_big5)} {len(f_enc_gb)} {len(f_enc_sjis)} {len(f_enc_euckr)}"
    )


if __name__ == "__main__":
    main()
