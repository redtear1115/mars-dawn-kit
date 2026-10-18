// Generated from the fixture in redtear1115/mars-dawn#414 (sections A, C and G), read
// programmatically from the issue body, not retyped.
// `baseHTML` is what the renderer produced for it at kit 1fe52c0 (tag 0.6.3), before `<details>`
// grouping.

enum DetailsFixture {
    static let markdown = #"""
# details fixture

結論：這行永遠要看得到。

## A. GitHub 標準寫法（有空行，內含 Markdown）

<details>
<summary>A 補充細節</summary>

A 內文 **粗體**、`code`

- A 清單一
- A 清單二

```js
console.log("A code");
```

</details>

A 之後的段落（不該被收進去）。

## C. 預設展開

<details open>
<summary>C 預設展開</summary>

C 內文

</details>

## G. 巢狀 details

<details>
<summary>G 外層</summary>

G 外文

<details>
<summary>G 內層</summary>

G 內文

</details>

</details>

最後一行：END-OF-FIXTURE

"""#
    static let baseHTML = #"""
<h1 id="details-fixture" data-line="1">details fixture</h1>
<p data-line="3">結論：這行永遠要看得到。</p>
<h2 id="a-github-標準寫法有空行內含-markdown" data-line="5">A. GitHub 標準寫法（有空行，內含 Markdown）</h2>
<div class="html-block" data-line="7"><details>
<summary>A 補充細節</summary>
</div>
<p data-line="10">A 內文 <strong>粗體</strong>、<code>code</code></p>
<ul data-line="12">
<li data-line="12">A 清單一
</li>
<li data-line="13">A 清單二
</li>
</ul>
<pre data-line="15"><code class="language-js">console.log("A code");
</code></pre>
<div class="html-block" data-line="19"></details>
</div>
<p data-line="21">A 之後的段落（不該被收進去）。</p>
<h2 id="c-預設展開" data-line="23">C. 預設展開</h2>
<div class="html-block" data-line="25"><details open>
<summary>C 預設展開</summary>
</div>
<p data-line="28">C 內文</p>
<div class="html-block" data-line="30"></details>
</div>
<h2 id="g-巢狀-details" data-line="32">G. 巢狀 details</h2>
<div class="html-block" data-line="34"><details>
<summary>G 外層</summary>
</div>
<p data-line="37">G 外文</p>
<div class="html-block" data-line="39"><details>
<summary>G 內層</summary>
</div>
<p data-line="42">G 內文</p>
<div class="html-block" data-line="44"></details>
</div>
<div class="html-block" data-line="46"></details>
</div>
<p data-line="48">最後一行：END-OF-FIXTURE</p>

"""#
}
