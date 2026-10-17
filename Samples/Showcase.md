---
title: Zquig MD showcase
tags: [markdown, preview]
---
# Zquig MD Showcase

A **fast**, _offline_ Markdown previewer. Links: [GitHub](https://github.com), [jump to tables](#tables), [another doc](Other.md).

> [!TIP]
> Edit this file in any editor and save — the preview reloads in place.

## Task list
- [x] GitHub-flavored Markdown
- [x] Syntax highlighting
- [ ] Your next idea

## Tables
| Feature | Status | Notes |
|:--|:-:|--:|
| Tables | ✅ | aligned |
| ~~Electron~~ | ❌ | never |

## Code
```swift
struct Greeting {
    let name: String
    func render() -> String { "Hello, \(name)!" } // interpolation
}
```

```python
def fib(n: int) -> int:
    return n if n < 2 else fib(n - 1) + fib(n - 2)
```

Inline `code`, <kbd>⌘</kbd><kbd>R</kbd>, and an autolink: https://example.com

## Image
![Local swatch](images/swatch.png)

<script>document.body.innerHTML = "SCRIPT RAN"</script>
