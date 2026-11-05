---
title: FM-TITLE-SECRET
author: FM-AUTHOR-SECRET
tags: FM-TAGS-SECRET
---

# Collapsible fixture (mars-dawn#300)

Intro paragraph: INTRO-ALWAYS.

## A. Collapsed details

<details>
<summary>SUMMARY-A</summary>

BODY-A first paragraph with **bold** text.

BODY-A2 second paragraph.

```js
console.log("BODY-A-CODE");
```

</details>

AFTER-A paragraph.

## C. Details written open

<details open>
<summary>SUMMARY-C</summary>

BODY-C paragraph.

</details>

## D. Spoiler, collapsed

:::spoiler SUMMARY-D
BODY-D paragraph.
:::

## E. Spoiler, open

:::spoiler {state="open"} SUMMARY-E
BODY-E paragraph.
:::

## F. Nested spoilers

::::spoiler SUMMARY-F-OUTER
BODY-F-OUTER paragraph.

:::spoiler SUMMARY-F-INNER
BODY-F-INNER paragraph.
:::

F outer after: BODY-F-AFTER.
::::

## G. Nested details

<details>
<summary>SUMMARY-G-OUTER</summary>

BODY-G-OUTER paragraph.

<details>
<summary>SUMMARY-G-INNER</summary>

BODY-G-INNER paragraph.

</details>

</details>

## H. Folded callout

> [!note]- SUMMARY-H
> BODY-H paragraph.

## I. Expanded callout

> [!tip]+ SUMMARY-I
> BODY-I paragraph.

## J. Plain callout

> [!NOTE]
> BODY-J paragraph.

## K. Long code block

```swift
let k01 = "BODY-K line 1"
let k02 = "BODY-K line 2"
let k03 = "BODY-K line 3"
let k04 = "BODY-K line 4"
let k05 = "BODY-K line 5"
let k06 = "BODY-K line 6"
let k07 = "BODY-K line 7"
let k08 = "BODY-K line 8"
let k09 = "BODY-K line 9"
let k10 = "BODY-K line 10"
let k11 = "BODY-K line 11"
let k12 = "BODY-K line 12"
let k13 = "BODY-K line 13"
let k14 = "BODY-K line 14"
let k15 = "BODY-K line 15"
let k16 = "BODY-K line 16"
let k17 = "BODY-K line 17"
let k18 = "BODY-K line 18"
let k19 = "BODY-K line 19"
let k20 = "BODY-K line 20"
let k21 = "BODY-K line 21"
let k22 = "BODY-K line 22"
let k23 = "BODY-K line 23"
let k24 = "BODY-K line 24"
let k25 = "BODY-K line 25"
let k26 = "BODY-K line 26"
let k27 = "BODY-K line 27"
let k28 = "BODY-K line 28"
let k29 = "BODY-K line 29"
let k30 = "BODY-K line 30"
let k31 = "BODY-K line 31"
let k32 = "BODY-K line 32"
let k33 = "BODY-K line 33"
let k34 = "BODY-K line 34"
let k35 = "BODY-K line 35"
let k36 = "BODY-K line 36"
let k37 = "BODY-K line 37"
let k38 = "BODY-K line 38"
let k39 = "BODY-K line 39"
let k40 = "BODY-K line 40"
let k41 = "BODY-K line 41"
let k42 = "BODY-K line 42"
```

END-OF-FIXTURE
