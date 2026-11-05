# readq-comic

Read comic book archives in Emacs, one page at a time: ZIP (`.cbz`), RAR
(`.cbr`) or 7z (`.cb7`) files of page images. Pages fit the window, and you
can zoom into them and pan around.

It works on its own, and [readq](https://github.com/n0w1ht/readq) uses it to
read the comics in its reading queue, where it tracks your page.

## Installation

```elisp
(add-to-list 'load-path "~/path/to/readq-comic")
(require 'readq-comic)
```

Then `M-x readq-comic-open` on a comic.

Pages are read with an archiver: readq-comic uses the first it finds of
7-Zip, bsdtar (Windows' own `tar.exe`), `unar` (it lists archives with
`lsar`, which comes with it), `unzip` (CBZ only) and `unrar` (CBR only), or
the one in `readq-comic-program`. 7-Zip, in `C:\Program Files\7-Zip\`, is
found even when it isn't on the `PATH`. Many `.cbr` files are really ZIP
files; readq-comic looks at the contents, not the name.

## Keys

| Key | Does |
|-----|------|
| `SPC` / `S-SPC` or `DEL` | scroll down / up the page, then on to the next / previous page; on a zoomed page wider than the window, go strip by strip, left to right |
| `n` `p`, `PgDn` `PgUp` | next / previous page |
| `→` `←` | pan right / left on a zoomed page wider than the window, else next / previous page |
| `↑` `↓` | scroll up / down a little |
| `+` or `=` / `-`, `C-wheel` | zoom in / out (on the mouse with `C-wheel`) |
| `0` | back to the fit |
| drag with the mouse | pan a zoomed page |
| `M-<` / `M->` | first / last page |
| `g` | go to a page |
| `w` / `h` | fit the window's width (scroll down tall pages with `SPC`) / show the whole page |

- **Pages** are the archive's images, sorted by name the way people number
  them (`page2` before `page10`). Pages in folders are read in order too.
- **Zoom** is relative to the fit and stays as you turn pages; the mode line
  shows it, e.g. `12/180 156%`. Resizing the window keeps a zoomed page's
  size and what is in the middle of the window.

## Options

| Option | Default | |
|---|---|---|
| `readq-comic-fit` | `page` | how a page fits the window at first: `page` (all of it) or `width` |
| `readq-comic-zoom-step` | `1.25` | how much each zoom in or out zooms |
| `readq-comic-max-pixels` | 24 million | the most pixels a zoomed page may have (about 100 MB of memory); zooming in stops there |
| `readq-comic-program` | nil (find one) | the archiver: 7-Zip, bsdtar, unar, unzip or unrar |

## For other programs

- `readq-comic-open-hook`: run in a comic's buffer after `readq-comic-open`
  shows it.
- `readq-comic-page-change-hook`: run after you go to another page.
- `readq-comic-current-file`, `readq-comic-current-page`,
  `readq-comic-page-count`: the comic of this buffer, the page shown (from
  1), and how many pages it has.
- `readq-comic-show-page`: show a page without running the page hook, as
  when going back to a saved page.
- `readq-comic-current-image`: the image data of the page shown.
- `readq-comic-count-pages`: the number of pages of a comic file.
- `readq-comic-programs`: the archivers found, best first.

## Running the tests

```sh
emacs -Q --batch -L . -l test/readq-comic-test.el -f ert-run-tests-batch-and-exit
```

Each archiver's tests run when it is installed: `7z`, `bsdtar`, `unar` and
`lsar`, `unzip`. unrar's are simulated. `test/fixtures/README` describes the
test comics.
