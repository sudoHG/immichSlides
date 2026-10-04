#!/usr/bin/env python3
"""Convert PRIVACY_POLICY.md into static HTML that can be uploaded directly to Cloudflare Pages.

This script uses no third-party libraries, because the privacy policy page should stay as simple as possible:
it opens with native browser features alone, and uploading it to Cloudflare Pages later needs no extra tools.
"""

from __future__ import annotations

import argparse
import html
import re
from pathlib import Path




ROOT = Path(__file__).resolve().parents[1]


SOURCE = ROOT / "PRIVACY_POLICY.md"



PRIVACY_URL = "https://slides.by331.net/privacy/"


def render_inline(text: str) -> str:
    """Render a short piece of inline Markdown.

    "Inline" means small formatting inside a paragraph, such as `code` in backticks.
    This is not a full Markdown parser; it only handles the inline formats the current privacy policy uses.
    """

    
    parts = text.split("`")
    rendered_parts: list[str] = []

    for index, part in enumerate(parts):
        
        escaped = html.escape(part)

        if index % 2 == 1:
            
            rendered_parts.append(f"<code>{escaped}</code>")
        else:
            
            rendered_parts.append(escaped)

    return "".join(rendered_parts)


def slugify(text: str, used_slugs: set[str]) -> str:
    """Turn heading text into an HTML id for in-page links."""

    
    special_slugs = {
        "中文": "chinese",
        "English": "english",
    }

    if text in special_slugs:
        base = special_slugs[text]
    else:
        
        ascii_text = re.sub(r"[^A-Za-z0-9\s-]", " ", text)
        base = re.sub(r"\s+", "-", ascii_text.strip().lower()).strip("-")

    
    if not base:
        base = "section"

    slug = base
    suffix = 2

    
    while slug in used_slugs:
        slug = f"{base}-{suffix}"
        suffix += 1

    used_slugs.add(slug)
    return slug


def is_table_separator(line: str) -> bool:
    """Return whether a Markdown line is a table separator row, such as |---|---|."""

    cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
    return bool(cells) and all(re.fullmatch(r":?-{3,}:?", cell) for cell in cells)


def split_table_row(line: str) -> list[str]:
    """Split one Markdown table row into cells."""

    return [cell.strip() for cell in line.strip().strip("|").split("|")]


def render_table(lines: list[str], start: int) -> tuple[str, int]:
    """Render a Markdown table as an HTML table and return the next read position."""

    header_cells = split_table_row(lines[start])
    index = start + 2
    body_rows: list[list[str]] = []

    
    while index < len(lines) and "|" in lines[index] and lines[index].strip():
        body_rows.append(split_table_row(lines[index]))
        index += 1

    header_html = "".join(f"<th>{render_inline(cell)}</th>" for cell in header_cells)
    body_html_parts: list[str] = []

    for row in body_rows:
        cells_html = "".join(f"<td>{render_inline(cell)}</td>" for cell in row)
        body_html_parts.append(f"<tr>{cells_html}</tr>")

    table_html = (
        '<div class="table-wrap">'
        "<table>"
        f"<thead><tr>{header_html}</tr></thead>"
        f"<tbody>{''.join(body_html_parts)}</tbody>"
        "</table>"
        "</div>"
    )

    return table_html, index


def parse_blocks(lines: list[str], used_slugs: set[str] | None = None) -> str:
    """Convert the Markdown block syntax used by the current privacy policy into HTML."""

    
    if used_slugs is None:
        used_slugs = set()

    html_blocks: list[str] = []
    index = 0

    while index < len(lines):
        line = lines[index]
        stripped = line.strip()

        if not stripped:
            index += 1
            continue

        if stripped == "---":
            html_blocks.append("<hr>")
            index += 1
            continue

        if stripped.startswith(">"):
            quote_lines: list[str] = []

            
            while index < len(lines) and lines[index].strip().startswith(">"):
                quote_line = lines[index].strip()[1:].lstrip()
                quote_lines.append(quote_line)
                index += 1

            quote_html = parse_blocks(quote_lines, used_slugs)
            html_blocks.append(f'<aside class="policy-note">{quote_html}</aside>')
            continue

        if re.match(r"^#{1,4}\s+", stripped):
            match = re.match(r"^(#{1,4})\s+(.+)$", stripped)
            assert match is not None
            level = len(match.group(1))
            title_text = match.group(2).strip()
            heading_id = slugify(title_text, used_slugs)
            heading_html = render_inline(title_text)
            html_blocks.append(
                f'<h{level} id="{heading_id}">'
                f'<a class="heading-anchor" href="#{heading_id}">'
                f"{heading_html}"
                "</a>"
                f"</h{level}>"
            )
            index += 1
            continue

        if (
            "|" in stripped
            and index + 1 < len(lines)
            and is_table_separator(lines[index + 1].strip())
        ):
            table_html, index = render_table(lines, index)
            html_blocks.append(table_html)
            continue

        if stripped.startswith("- "):
            item_html_parts: list[str] = []

            
            while index < len(lines) and lines[index].strip().startswith("- "):
                item_text = lines[index].strip()[2:].strip()
                item_html_parts.append(f"<li>{render_inline(item_text)}</li>")
                index += 1

            html_blocks.append(f"<ul>{''.join(item_html_parts)}</ul>")
            continue

        paragraph_lines = [stripped]
        index += 1

        
        while index < len(lines):
            next_line = lines[index].strip()

            if (
                not next_line
                or next_line == "---"
                or next_line.startswith(">")
                or next_line.startswith("- ")
                or re.match(r"^#{1,4}\s+", next_line)
                or (
                    "|" in next_line
                    and index + 1 < len(lines)
                    and is_table_separator(lines[index + 1].strip())
                )
            ):
                break

            paragraph_lines.append(next_line)
            index += 1

        paragraph_text = " ".join(paragraph_lines)
        html_blocks.append(f"<p>{render_inline(paragraph_text)}</p>")

    return "\n".join(html_blocks)


def read_policy_markdown() -> tuple[str, str, list[str]]:
    """Read the Markdown and split out the page title, update date and body."""

    markdown = SOURCE.read_text(encoding="utf-8")
    lines = markdown.splitlines()

    title = "immichSlides Privacy Policy"
    last_updated = ""
    content_start = 0

    if lines and lines[0].startswith("# "):
        title = lines[0].removeprefix("# ").strip()
        content_start = 1

    for position, line in enumerate(lines):
        if line.startswith("最后更新 / Last Updated:"):
            last_updated = line.removeprefix("最后更新 / Last Updated:").strip()
            content_start = position + 1
            break

    while content_start < len(lines) and not lines[content_start].strip():
        content_start += 1

    return title, last_updated, lines[content_start:]


def build_html_document(title: str, last_updated: str, article_html: str) -> str:
    """Combine the page shell, styles and policy body into a complete HTML file."""

    escaped_title = html.escape(title)
    escaped_last_updated = html.escape(last_updated)

    return f"""<!doctype html>
<!--
  这个文件由 scripts/build_privacy_policy_page.py 自动生成。
  如果要修改隐私政策正文，请先改根目录 PRIVACY_POLICY.md，再重新运行生成脚本。
-->
<html lang="zh-Hans">
<head>
  <!-- charset 告诉浏览器这个文件使用 UTF-8 编码，中文和英文才能稳定显示。 -->
  <meta charset="utf-8">

  <!-- viewport 让手机浏览器按设备宽度排版，避免页面被当成桌面网页缩小显示。 -->
  <meta name="viewport" content="width=device-width, initial-scale=1">

  <!-- title 会显示在浏览器标签页、收藏夹和搜索结果标题里。 -->
  <title>{escaped_title}</title>

  <!-- description 是页面摘要，搜索引擎和分享预览可能会读取它。 -->
  <meta name="description" content="Privacy Policy for immichSlides, an unofficial slideshow app for self-hosted Immich servers.">

  <style>
    /* :root 保存全局颜色和尺寸变量，后面重复使用时更容易统一调整。 */
    :root {{
      color-scheme: light dark;
      --page-bg: #f6f7f9;
      --panel-bg: #ffffff;
      --text: #17202a;
      --muted: #5d6b7a;
      --border: #d9e0e8;
      --accent: #1f6feb;
      --accent-soft: #e8f1ff;
      --warning-bg: #fff7df;
      --warning-border: #e0b341;
      --code-bg: #eef1f4;
      --shadow: 0 18px 40px rgba(23, 32, 42, 0.08);
      --content-width: 980px;
    }}

    /* 深色模式下换一组颜色，保证文字和背景仍然有足够对比度。 */
    @media (prefers-color-scheme: dark) {{
      :root {{
        --page-bg: #101418;
        --panel-bg: #171d23;
        --text: #eef3f8;
        --muted: #a7b2be;
        --border: #303a45;
        --accent: #78a9ff;
        --accent-soft: #14233a;
        --warning-bg: #2b2412;
        --warning-border: #b9922f;
        --code-bg: #26313c;
        --shadow: none;
      }}
    }}

    /* border-box 让元素宽度包含 padding 和 border，响应式布局更不容易溢出。 */
    *, *::before, *::after {{
      box-sizing: border-box;
    }}

    /* html 开启平滑滚动，点击顶部语言链接时会柔和跳转到对应章节。 */
    html {{
      scroll-behavior: smooth;
    }}

    /* body 是整个页面的基础排版容器。 */
    body {{
      margin: 0;
      background: var(--page-bg);
      color: var(--text);
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif;
      font-size: 16px;
      line-height: 1.72;
    }}

    /* 顶部区域给页面一个清晰标题，但不引入复杂装饰。 */
    .site-header {{
      padding: 48px 20px 28px;
    }}

    /* header-inner 限制标题区最大宽度，让宽屏阅读时行长不会过长。 */
    .header-inner {{
      width: min(100%, var(--content-width));
      margin: 0 auto;
    }}

    /* eyebrow 是标题上方的小标签，用来标出应用名称。 */
    .eyebrow {{
      margin: 0 0 8px;
      color: var(--accent);
      font-size: 0.88rem;
      font-weight: 700;
      letter-spacing: 0;
    }}

    /* 页面主标题使用较大字号，但限制最大值，避免手机上挤压布局。 */
    .site-title {{
      margin: 0;
      font-size: clamp(2rem, 7vw, 3.5rem);
      line-height: 1.08;
      letter-spacing: 0;
    }}

    /* 更新时间是辅助信息，所以颜色比正文更弱。 */
    .updated {{
      margin: 14px 0 0;
      color: var(--muted);
      font-size: 1rem;
    }}

    /* language-nav 是语言快捷入口；使用 flex-wrap 防止小屏幕挤出屏幕。 */
    .language-nav {{
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
      margin-top: 24px;
    }}

    /* 顶部链接做成清晰可点的胶囊按钮，方便手机用户点击。 */
    .language-nav a {{
      display: inline-flex;
      align-items: center;
      min-height: 40px;
      padding: 8px 14px;
      border: 1px solid var(--border);
      border-radius: 999px;
      background: var(--panel-bg);
      color: var(--text);
      text-decoration: none;
      font-weight: 650;
    }}

    /* hover 和 focus-visible 让鼠标悬停、键盘聚焦时都有明确反馈。 */
    .language-nav a:hover,
    .language-nav a:focus-visible {{
      border-color: var(--accent);
      color: var(--accent);
      outline: none;
    }}

    /* main 是正文外层，负责给页面左右留白。 */
    main {{
      padding: 0 20px 56px;
    }}

    /* policy-content 是真正承载隐私政策的阅读面板。 */
    .policy-content {{
      width: min(100%, var(--content-width));
      margin: 0 auto;
      padding: clamp(24px, 5vw, 48px);
      border: 1px solid var(--border);
      border-radius: 8px;
      background: var(--panel-bg);
      box-shadow: var(--shadow);
    }}

    /* 标题滚动定位时预留顶部空间，避免锚点跳转后标题贴住浏览器顶部。 */
    .policy-content h2,
    .policy-content h3,
    .policy-content h4 {{
      scroll-margin-top: 24px;
    }}

    /* 二级标题用于中文和英文大章节，视觉上要明显。 */
    .policy-content h2 {{
      margin: 38px 0 16px;
      padding-bottom: 10px;
      border-bottom: 1px solid var(--border);
      font-size: clamp(1.65rem, 5vw, 2.25rem);
      line-height: 1.2;
      letter-spacing: 0;
    }}

    /* 三级标题用于每一条政策章节。 */
    .policy-content h3 {{
      margin: 30px 0 12px;
      font-size: clamp(1.2rem, 4vw, 1.45rem);
      line-height: 1.32;
      letter-spacing: 0;
    }}

    /* 四级标题用于地区补充说明里的国家或地区名称。 */
    .policy-content h4 {{
      margin: 24px 0 8px;
      font-size: 1.06rem;
      line-height: 1.35;
      letter-spacing: 0;
    }}

    /* 段落上下留白保持克制，让长政策文本仍然容易连续阅读。 */
    .policy-content p {{
      margin: 0 0 14px;
    }}

    /* heading-anchor 让标题本身可以作为锚点链接，但视觉上仍像普通标题。 */
    .heading-anchor {{
      color: inherit;
      text-decoration: none;
    }}

    /* focus-visible 只在键盘聚焦时显示轮廓，不影响鼠标点击阅读。 */
    .heading-anchor:focus-visible {{
      outline: 3px solid var(--accent);
      outline-offset: 4px;
      border-radius: 4px;
    }}

    /* policy-note 用来突出发布前必须填写的占位项。 */
    .policy-note {{
      margin: 0 0 28px;
      padding: 18px 20px;
      border: 1px solid var(--warning-border);
      border-radius: 8px;
      background: var(--warning-bg);
    }}

    /* 提示块里的最后一个元素不再额外留底部空白，视觉更紧凑。 */
    .policy-note > :last-child {{
      margin-bottom: 0;
    }}

    /* 列表使用正常缩进，方便用户快速扫读条目。 */
    ul {{
      margin: 0 0 16px;
      padding-left: 1.35rem;
    }}

    /* 列表项之间留一点距离，长句不会粘在一起。 */
    li + li {{
      margin-top: 6px;
    }}

    /* 表格外层允许小屏横向滚动，避免整页被宽表格撑出屏幕。 */
    .table-wrap {{
      width: 100%;
      margin: 18px 0 24px;
      overflow-x: auto;
      border: 1px solid var(--border);
      border-radius: 8px;
    }}

    /* 表格使用合并边框，并设置最小宽度来保护列信息。 */
    table {{
      width: 100%;
      min-width: 760px;
      border-collapse: collapse;
      background: var(--panel-bg);
    }}

    /* 表头颜色稍深，用户能看出每列含义。 */
    th {{
      background: var(--accent-soft);
      color: var(--text);
      font-weight: 700;
      text-align: left;
    }}

    /* 单元格统一内边距和边框，长文本自动换行。 */
    th,
    td {{
      padding: 12px 14px;
      border-bottom: 1px solid var(--border);
      vertical-align: top;
      overflow-wrap: anywhere;
    }}

    /* 最后一行不需要底部分隔线，表格边缘更干净。 */
    tbody tr:last-child td {{
      border-bottom: 0;
    }}

    /* 行内代码用于显示 API Key、soloOnly 这类技术名词。 */
    code {{
      padding: 0.12em 0.35em;
      border-radius: 4px;
      background: var(--code-bg);
      font-family: "SF Mono", Menlo, Consolas, monospace;
      font-size: 0.92em;
    }}

    /* 分割线对应 Markdown 里的 ---，用于分隔中英文部分前的结构。 */
    hr {{
      margin: 32px 0;
      border: 0;
      border-top: 1px solid var(--border);
    }}

    /* 页脚放上传提醒和来源说明，不抢正文注意力。 */
    .site-footer {{
      width: min(100%, var(--content-width));
      margin: 0 auto;
      padding: 0 20px 40px;
      color: var(--muted);
      font-size: 0.92rem;
    }}

    /* 打印时去掉背景和阴影，方便导出 PDF 或纸质审阅。 */
    @media print {{
      body {{
        background: #ffffff;
      }}

      .site-header,
      main,
      .site-footer {{
        padding-left: 0;
        padding-right: 0;
      }}

      .policy-content {{
        border: 0;
        box-shadow: none;
      }}
    }}

    /* 小屏幕下压缩边距，让正文有更多可用宽度。 */
    @media (max-width: 640px) {{
      .site-header {{
        padding-top: 32px;
      }}

      .policy-content {{
        padding: 22px 18px;
      }}

      table {{
        min-width: 680px;
      }}
    }}
  </style>
</head>
<body>
  <header class="site-header">
    <div class="header-inner">
      <p class="eyebrow">immichSlides</p>
      <h1 class="site-title">{escaped_title}</h1>
      <p class="updated">Last updated: {escaped_last_updated}</p>
      <nav class="language-nav" aria-label="Language shortcuts">
        <a href="#chinese">中文</a>
        <a href="#english">English</a>
      </nav>
    </div>
  </header>

  <main>
    <article class="policy-content">
{article_html}
    </article>
  </main>

  <footer class="site-footer">
    <p>immichSlides Privacy Policy</p>
  </footer>
</body>
</html>
"""


def build_root_redirect_document() -> str:
    """Build the root-address compatibility page that redirects the old root path to the new /privacy/."""

    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="refresh" content="0; url=/privacy/">
  <link rel="canonical" href="{PRIVACY_URL}">
  <title>immichSlides</title>
  <style>
    :root {{
      color-scheme: light dark;
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif;
    }}

    body {{
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      padding: 24px;
      background: Canvas;
      color: CanvasText;
      line-height: 1.6;
    }}

    main {{
      width: min(100%, 620px);
    }}

    a {{
      color: LinkText;
      overflow-wrap: anywhere;
    }}
  </style>
</head>
<body>
  <main>
    <h1>immichSlides</h1>
    <p>The privacy policy has moved to <a href="/privacy/">https://slides.by331.net/privacy/</a>.</p>
    <p>Support is available at <a href="/support/">https://slides.by331.net/support/</a>.</p>
  </main>
</body>
</html>
"""


def main() -> None:
    """Script entry point: read Markdown, generate HTML and write the web page files."""

    parser = argparse.ArgumentParser(description="Generate the static privacy policy page.")
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=ROOT / "build" / "privacy-site",
        help="Directory for the generated pages (default: build/privacy-site).",
    )
    output_directory = parser.parse_args().output_dir.expanduser().resolve()
    privacy_output = output_directory / "privacy" / "index.html"
    root_redirect_output = output_directory / "index.html"

    title, last_updated, content_lines = read_policy_markdown()
    article_html = parse_blocks(content_lines)
    privacy_output.parent.mkdir(parents=True, exist_ok=True)
    privacy_output.write_text(build_html_document(title, last_updated, article_html), encoding="utf-8")
    root_redirect_output.write_text(build_root_redirect_document(), encoding="utf-8")

    for output in (privacy_output, root_redirect_output):
        try:
            display_path = output.relative_to(ROOT)
        except ValueError:
            display_path = output
        print(f"Generated {display_path}")


if __name__ == "__main__":
    main()
