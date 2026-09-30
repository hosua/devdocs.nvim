# `grid-template-areas` CSS property

**Baseline Widely available**

This feature is well established and works across many devices and browser versions. It's been available across browsers since October 2017.

The **`grid-template-areas`** [CSS](https://developer.mozilla.org/en-US/docs/Web/CSS) property specifies named [grid areas](https://developer.mozilla.org/en-US/docs/Glossary/grid_areas), establishing the cells in the grid and assigning them names.

Those areas are not associated with any particular grid item, but can be referenced from the grid-placement properties [`grid-row-start`](devdocs://css/properties/grid-row-start), [`grid-row-end`](devdocs://css/properties/grid-row-end), [`grid-column-start`](devdocs://css/properties/grid-column-start), [`grid-column-end`](devdocs://css/properties/grid-column-end), and their shorthands [`grid-row`](devdocs://css/properties/grid-row), [`grid-column`](devdocs://css/properties/grid-column), and [`grid-area`](devdocs://css/properties/grid-area).

## Try it

```css
grid-template-areas:
  "a a a"
  "b c c"
  "b c c";
```

```css
grid-template-areas:
  "b b a"
  "b b c"
  "b b c";
```

```css
grid-template-areas:
  "a a ."
  "a a ."
  ". b c";
```

```html
<section class="default-example" id="default-example">
  <div class="example-container">
    <div class="transition-all" id="example-element">
      <div>One (a)</div>
      <div>Two (b)</div>
      <div>Three (c)</div>
    </div>
  </div>
</section>
```

```css
#example-element {
  border: 1px solid #c5c5c5;
  display: grid;
  grid-template-columns: 1fr 1fr 1fr;
  grid-template-rows: repeat(3, minmax(40px, auto));
  grid-gap: 10px;
  width: 200px;
}

#example-element :nth-child(1) {
  background-color: rgb(0 0 255 / 0.2);
  border: 3px solid blue;
  grid-area: a;
}

#example-element :nth-child(2) {
  background-color: rgb(255 0 200 / 0.2);
  border: 3px solid rebeccapurple;
  grid-area: b;
}

#example-element :nth-child(3) {
  background-color: rgb(94 255 0 / 0.2);
  border: 3px solid green;
  grid-area: c;
}
```

## Syntax

```css
/* Keyword value */
grid-template-areas: none;

/* <string> values */
grid-template-areas: "a b";
grid-template-areas:
  "a b ."
  "a c d";

/* Global values */
grid-template-areas: inherit;
grid-template-areas: initial;
grid-template-areas: revert;
grid-template-areas: revert-layer;
grid-template-areas: unset;
```

### Values

**[`none`](devdocs://css/properties/grid-template-areas#none)**
  The grid container doesn't define any named grid areas.

**[`<string>`](devdocs://css/values/string)**

  A row is created for every separate string listed, and a column is created for each cell in the string. Multiple cell tokens with the same name within and between rows create a single named grid area that spans the corresponding grid cells. Unless those cells form a rectangle, the declaration is invalid.

  All the remaining unnamed areas in a grid can be referred using *null cell tokens*. A null cell token is a sequence of one or more `.` (U+002E FULL STOP) characters, e.g., `.`, `...`, or `.....` etc. A null cell token can be used to create empty spaces in the grid.

## Formal definition

| Initial value  | none            |
| -------------- | --------------- |
| Applies to     | grid containers |
| Inherited      | no              |
| Computed value | as specified    |
| Animation type | discrete        |

## Formal syntax

```
grid-template-areas = 
  none |
  <string>+
```

## Examples

### Specifying named grid areas

#### HTML

```html
<div id="page">
  <header>Header</header>
  <nav>Navigation</nav>
  <main>Main area</main>
  <footer>Footer</footer>
</div>
```

#### CSS

```css
#page {
  display: grid;
  width: 100%;
  height: 250px;
  grid-template-areas:
    "head head"
    "nav  main"
    ".  foot";
  grid-template-rows: 50px 1fr 30px;
  grid-template-columns: 150px 1fr;
}

#page > header {
  grid-area: head;
  background-color: #8ca0ff;
}

#page > nav {
  grid-area: nav;
  background-color: #ffa08c;
}

#page > main {
  grid-area: main;
  background-color: #ffff64;
}

#page > footer {
  grid-area: foot;
  background-color: #8cffa0;
}
```

In the above code, a null token (`.`) was used to create an unnamed area in the grid container, which we used to create an empty space at the bottom left corner of the grid.

#### Result

## Specifications

| Specification                                                 |
| ------------------------------------------------------------- |
| CSS Grid Layout Module Level 2 # grid-template-areas-property |

## Browser compatibility

|                       | Desktop | Mobile |         |       |        |                |                     |               |               |                  |                 |                |
| --------------------- | ------- | ------ | ------- | ----- | ------ | -------------- | ------------------- | ------------- | ------------- | ---------------- | --------------- | -------------- |
|                       | Chrome  | Edge   | Firefox | Opera | Safari | Chrome Android | Firefox for Android | Opera Android | Safari on iOS | Samsung Internet | WebView Android | WebView on iOS |
| `grid-template-areas` | 57      | 16     | 52      | 44    | 10.1   | 57             | 52                  | 43            | 10.3          | 6.0              | 57              | 10.3           |
| `none`                | 57      | 79     | 52      | 44    | 10.1   | 57             | 52                  | 43            | 10.3          | 7.0              | 57              | 10.3           |

## See also

- [`grid-template-rows`](devdocs://css/properties/grid-template-rows)
- [`grid-template-columns`](devdocs://css/properties/grid-template-columns)
- [`grid-template`](devdocs://css/properties/grid-template)
- [Grid template areas](https://developer.mozilla.org/en-US/docs/Web/CSS/Guides/Grid_layout/Grid_template_areas)
- Video: [Grid template areas](https://gridbyexample.com/video/grid-template-areas/)

© 2005–2025 MDN contributors.
Licensed under the Creative Commons Attribution-ShareAlike License v2.5 or later.
[https://developer.mozilla.org/en-US/docs/Web/CSS/Reference/Properties/grid-template-areas](https://developer.mozilla.org/en-US/docs/Web/CSS/Reference/Properties/grid-template-areas)
