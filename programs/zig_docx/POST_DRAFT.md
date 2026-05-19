I had a 337 MB Claude conversations export sitting on my disk and no good way to grep it. Python tooling either OOM'd or took half an hour. So I wrote `zig-docx` — pure Zig, 3.6 MB static binary, no libc.

682 conversations, 11,491 messages, 5,658 artifacts in **5.7 seconds**.

While I was at it I made the whole thing bidirectional:

- **AI workflow:** LLM emits markdown → ship a real `.docx`. Letterhead, tables, embedded images, drawing-object IDs that pass strict validators.
- **Authoring workflow:** humans write `.docx` → your blog ingests MDX. Frontmatter generated from the doc, images preserved, tables intact.

PDF, XLSX, and Anthropic JSON exports feed in too. Anything that comes out as markdown can be chunked for RAG with a section-aware chunker that:

- splits at `#` / `##` headers; never inside fenced code blocks or markdown tables
- merges sections under 500 words, splits over 8,000 at paragraph boundaries
- emits MD5-hashed cross-references between chunks for retrievable citations

1,529-page PDF → 417 chunks in **4.20 seconds, 40 MB peak RAM**.

```
zig-docx manual.pdf --chunk -o chunks/
```

Same source tree, three artifacts: CLI binary, C-callable static library, and a 3.1 MB WASI module that runs in Node, browsers, and edge runtimes.

Repo: <link>. MIT.
