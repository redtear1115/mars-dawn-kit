#if os(macOS)
// Generated from the fixture in redtear1115/mars-dawn#414 (sections A, C and G), read
// programmatically from the issue body, not retyped.

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
}
#endif
