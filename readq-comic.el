;;; readq-comic.el --- Read comic book archives one page at a time  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Hormoz Zamanpour Siahkal

;; Author: Hormoz Zamanpour Siahkal <n0w1ht@users.noreply.github.com>
;; URL: https://github.com/n0w1ht/readq-comic
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: multimedia, files

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; A comic book archive is a ZIP (.cbz), RAR (.cbr) or 7z (.cb7) file
;; of page images.  `readq-comic-open' shows its pages one at a time in
;; `readq-comic-mode', fit to the window, to zoom into and pan around.
;; Pages are read from the archive with an archiver: 7-Zip, bsdtar (the
;; tar.exe of Windows 10 and later), unar, unzip or unrar.
;;
;; readq uses it to read comics from its queue, and tracks the page
;; through `readq-comic-open-hook' and `readq-comic-page-change-hook'.
;; For such programs:
;;   `readq-comic-current-file'  the comic of this buffer
;;   `readq-comic-current-page'  the page shown, from 1
;;   `readq-comic-page-count'    how many pages it has
;;   `readq-comic-show-page'     show a page, without running the hook
;;   `readq-comic-current-image' the image data of the page shown
;;   `readq-comic-count-pages'   the number of pages of a comic file
;;   `readq-comic-programs'      the archivers found

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function image-size "image.c" (spec &optional pixels frame))
(declare-function json-read-from-string "json" (string))
(defvar json-object-type)
(defvar json-array-type)
(defvar json-key-type)

;;;; Options

(defgroup readq-comic nil
  "Read comic book archives (CBZ, CBR, CB7) one page at a time."
  :group 'multimedia
  :prefix "readq-comic-")

(defcustom readq-comic-program nil
  "Archiver used to read the pages of comics, or nil to find one.
When nil, readq-comic uses the first it finds of 7-Zip (7z), bsdtar (on
Windows, the tar that comes with Windows), unar (with its lsar), unzip
\(CBZ only) and unrar (CBR only).  Otherwise, the program's file name;
its kind is told from its name."
  :type '(choice (const :tag "Find one" nil) file)
  :group 'readq-comic)

(defcustom readq-comic-fit 'page
  "How a comic page fits the window: `page' (all of it) or `width'.
`w' and `h' in `readq-comic-mode' switch between them."
  :type '(choice (const :tag "Whole page" page) (const :tag "Window width" width))
  :group 'readq-comic)

(defconst readq-comic--image-re "\\.\\(jpe?g\\|png\\|gif\\|webp\\|bmp\\|avif\\|jxl\\)\\'"
  "Names of the entries of a comic that are pages.")

(defcustom readq-comic-open-hook nil
  "Hook run in a comic's buffer after `readq-comic-open' shows it."
  :type 'hook
  :group 'readq-comic)

(defcustom readq-comic-page-change-hook nil
  "Hook run in a comic's buffer after you go to another page.
It runs for the page commands (`readq-comic-next-page'...), not for
`readq-comic-show-page'."
  :type 'hook
  :group 'readq-comic)

(defconst readq-comic-file-re "\\.cb[zr7]\\'"
  "Names of the files that are comics.")

(defvar-local readq-comic--file nil
  "The comic file shown in this `readq-comic-mode' buffer.")
(put 'readq-comic--file 'permanent-local t)

(defvar-local readq-comic--pages nil
  "The page entries of the comic in this buffer, in order.")

(defvar-local readq-comic--page 1
  "The page shown in this buffer, from 1.")

(defvar-local readq-comic--fit nil
  "How pages fit the window in this buffer: `page' or `width'.")

(defvar-local readq-comic--zoom 1.0
  "Zoom of this buffer's pages, relative to their fit (see `readq-comic--fit').
It stays as you turn pages.")

(defcustom readq-comic-zoom-step 1.25
  "Factor by which `readq-comic-zoom-in' and `readq-comic-zoom-out' zoom."
  :type 'number
  :group 'readq-comic)

(defvar-local readq-comic--cache nil
  "Recently shown pages of this buffer's comic, as (ENTRY . DATA), newest first.")

;;;; Archives

(defun readq-comic--kind (file)
  "Return `zip' or `rar' from the first bytes of FILE, or nil."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file nil 0 8)
    (cond ((looking-at "PK\003\004\\|PK\005\006") 'zip)
          ((looking-at "Rar!\032\007") 'rar)
          ((looking-at "7z\274\257\047\034") '7z))))

(defun readq-comic--tool-kind (program)
  "Return the kind of archiver PROGRAM: `7z', `bsdtar', `unar', `unzip' or `unrar'."
  (let ((name (downcase (file-name-base program))))
    (cond ((string-match-p "\\`7z" name) '7z)
          ((string-match-p "\\`\\(unar\\|lsar\\)" name) 'unar)
          ((string-match-p "tar" name) 'bsdtar)
          ((string-match-p "unzip" name) 'unzip)
          ((string-match-p "unrar" name) 'unrar))))

(defun readq-comic--bsdtar-p (program)
  "Return non-nil when PROGRAM is bsdtar (libarchive), which reads ZIP and RAR."
  (with-temp-buffer
    (and (eql 0 (ignore-errors (call-process program nil t nil "--version")))
         (progn (goto-char (point-min)) (search-forward "bsdtar" nil t)))))

(defun readq-comic-programs ()
  "Return the archivers found, as (KIND . PROGRAM), best first."
  (if readq-comic-program
      (list (cons (readq-comic--tool-kind readq-comic-program) readq-comic-program))
    (delq nil
          (list (when-let* ((p (or (executable-find "7z") (executable-find "7zz")
                                  (executable-find "7za")
                                  (cl-find-if #'file-executable-p
                                              '("C:/Program Files/7-Zip/7z.exe"
                                                "C:/Program Files (x86)/7-Zip/7z.exe")))))
                  (cons '7z p))
                (when-let* ((p (or (executable-find "bsdtar")
                                  (let ((tar (executable-find "tar")))
                                    (and tar (readq-comic--bsdtar-p tar) tar)))))
                  (cons 'bsdtar p))
                (when-let* ((p (executable-find "unar"))) (cons 'unar p))
                (when-let* ((p (executable-find "unzip"))) (cons 'unzip p))
                (when-let* ((p (executable-find "unrar"))) (cons 'unrar p))))))

(defun readq-comic--program (file)
  "Return (KIND . PROGRAM), an archiver that can read FILE."
  (let ((kind (readq-comic--kind file)))
    (or (cl-find-if (lambda (tool)
                      (pcase (car tool)
                        ((or '7z 'bsdtar 'unar) t)
                        ('unzip (eq kind 'zip))
                        ('unrar (eq kind 'rar))))
                    (readq-comic-programs))
        (user-error "Cannot read %s: install 7-Zip (or set `readq-comic-program')"
                    (file-name-nondirectory file)))))

(defun readq-comic--run (tool &rest args)
  "Run the archiver TOOL, (KIND . PROGRAM), with ARGS; return its output.
The output is a unibyte string.  Signal an error if it fails."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (let* ((coding-system-for-read 'no-conversion)
           (coding-system-for-write 'utf-8)
           ;; Names in the archive are read and passed as UTF-8.
           (process-environment (if (memq system-type '(windows-nt ms-dos))
                                    process-environment
                                  (cons "LC_ALL=C.UTF-8" process-environment)))
           (status (apply #'call-process (cdr tool) nil '(t nil) nil args)))
      (unless (eql status 0)
        (error "readq-comic: %s failed (%s) on %s" (cdr tool) status (car (last args 2))))
      (buffer-string))))

(defun readq-comic--unar-tool (tool name)
  "Return TOOL, an unar archiver, as the program NAME: \"unar\" or \"lsar\".
unar lists archives with lsar, which comes with it."
  (let* ((prog (cdr tool))
         (dir (file-name-directory prog))
         (sibling (and dir (expand-file-name
                            (concat name (if (string-suffix-p ".exe" (downcase prog)) ".exe" ""))
                            dir))))
    (cons 'unar (cond ((string-prefix-p name (downcase (file-name-nondirectory prog))) prog)
                      ((and sibling (file-exists-p sibling)) sibling)
                      ((executable-find name))
                      (t (user-error "Cannot find %s, which comes with unar" name))))))

(defvar readq-comic--unar-entries-cache nil
  "The last archive listed with lsar, as (FILE MTIME . ENTRIES).")

(defun readq-comic--unar-entries (tool file)
  "Return the entries of FILE as (NAME . INDEX), listed with TOOL's lsar."
  (let ((mtime (file-attribute-modification-time (file-attributes file))))
    (if (and (equal (car readq-comic--unar-entries-cache) file)
             (equal (cadr readq-comic--unar-entries-cache) mtime))
        (cddr readq-comic--unar-entries-cache)
      (require 'json)
      (let* ((json (let ((json-object-type 'alist) (json-array-type 'list)
                         (json-key-type 'symbol))
                     (json-read-from-string
                      (readq-comic--run (readq-comic--unar-tool tool "lsar") "-ja" "--" file))))
             (entries (delq nil
                            (mapcar (lambda (e)
                                      (unless (eql (alist-get 'XADIsDirectory e) 1)
                                        (cons (alist-get 'XADFileName e)
                                              (alist-get 'XADIndex e))))
                                    (alist-get 'lsarContents json)))))
        (setq readq-comic--unar-entries-cache (cons file (cons mtime entries)))
        entries))))

(defun readq-comic--list (file)
  "Return the names of all entries of the archive FILE."
  (let* ((tool (readq-comic--program file))
         (file (expand-file-name file))
         (out (decode-coding-string
               (pcase (car tool)
                 ('unar "")
                 ('7z (readq-comic--run tool "l" "-ba" "-slt" "-sccUTF-8" "--" file))
                 ('bsdtar (readq-comic--run tool "-tf" file))
                 ('unzip (readq-comic--run tool "-Z1" file))
                 ('unrar (readq-comic--run tool "lb" "--" file)))
               'utf-8)))
    (cond
     ((eq (car tool) 'unar) (mapcar #'car (readq-comic--unar-entries tool file)))
     ((eq (car tool) '7z)
      (let (names)
        (dolist (line (split-string out "\r?\n"))
          (when (string-match "\\`Path = \\(.*\\)" line)
            (push (match-string 1 line) names)))
        (nreverse names)))
     (t (split-string out "\r?\n" t)))))

(defun readq-comic--page-list (file)
  "Return the page entries of comic FILE: its images, in reading order."
  (sort (cl-remove-if-not
         (lambda (name)
           (and (string-match-p readq-comic--image-re (downcase name))
                ;; macOS leaves these behind in archives.
                (not (string-match-p "\\(\\`\\|/\\)\\(__MACOSX/\\|\\._\\)" name))))
         (mapcar (lambda (n) (replace-regexp-in-string "\\\\" "/" n))
                 (readq-comic--list file)))
        (lambda (a b) (string-version-lessp (downcase a) (downcase b)))))

(defun readq-comic--unwild (entry)
  "Return ENTRY as a pattern of bsdtar and unzip that matches only itself.
They take names as wildcards, and their escapes differ by system; each
of [ ] * ? becomes ?, which matches it."
  (replace-regexp-in-string "[][*?]" "?" entry))

(defun readq-comic--page-data (file entry)
  "Return the image data of ENTRY in the comic FILE, a unibyte string."
  (let ((tool (readq-comic--program file))
        (file (expand-file-name file)))
    (pcase (car tool)
      ('7z (readq-comic--run tool "e" "-so" "-sccUTF-8" "--" file entry))
      ('bsdtar (readq-comic--run tool "-xOf" file (readq-comic--unwild entry)))
      ;; unar takes wildcards too, but also indexes, from lsar.
      ('unar (let ((index (cdr (cl-find-if
                                (lambda (e) (member entry (list (car e)
                                                                (replace-regexp-in-string
                                                                 "\\\\" "/" (car e)))))
                                (readq-comic--unar-entries tool file)))))
               (unless index (error "readq-comic: no %s in %s" entry file))
               (readq-comic--run (readq-comic--unar-tool tool "unar") "-q" "-o" "-" "-i" "--"
                                 file (number-to-string index))))
      ('unzip (readq-comic--run tool "-p" "--" file (readq-comic--unwild entry)))
      ('unrar (readq-comic--run tool "p" "-inul" "--" file entry)))))

(defun readq-comic-count-pages (file)
  "Return the number of pages of the comic FILE, or nil if it can't be read."
  (ignore-errors (length (readq-comic--page-list file))))

;;;; Viewing

(defvar readq-comic-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map " " #'readq-comic-scroll-forward)
    (define-key map (kbd "S-SPC") #'readq-comic-scroll-backward)
    (define-key map (kbd "DEL") #'readq-comic-scroll-backward)
    (define-key map "n" #'readq-comic-next-page)
    (define-key map "p" #'readq-comic-previous-page)
    (define-key map [next] #'readq-comic-next-page)
    (define-key map [prior] #'readq-comic-previous-page)
    (define-key map [right] #'readq-comic-next-page)
    (define-key map [left] #'readq-comic-previous-page)
    (define-key map (kbd "M-<") #'readq-comic-first-page)
    (define-key map (kbd "M->") #'readq-comic-last-page)
    (define-key map "g" #'readq-comic-goto-page)
    (define-key map "w" #'readq-comic-fit-width)
    (define-key map "h" #'readq-comic-fit-page)
    (define-key map "+" #'readq-comic-zoom-in)
    (define-key map "=" #'readq-comic-zoom-in)
    (define-key map "-" #'readq-comic-zoom-out)
    (define-key map "0" #'readq-comic-zoom-reset)
    (define-key map [up] #'readq-comic-scroll-up)
    (define-key map [down] #'readq-comic-scroll-down)
    (define-key map [right] #'readq-comic-right)
    (define-key map [left] #'readq-comic-left)
    (define-key map [down-mouse-1] #'readq-comic-drag)
    (define-key map [mouse-1] #'ignore)
    (dolist (key '([C-wheel-up] [C-mouse-4]))
      (define-key map key #'readq-comic-zoom-in))
    (dolist (key '([C-wheel-down] [C-mouse-5]))
      (define-key map key #'readq-comic-zoom-out))
    map)
  "Keymap for `readq-comic-mode'.")

(define-derived-mode readq-comic-mode special-mode "Comic"
  "Major mode showing a comic (CBZ or CBR) one page at a time.
Zoom with \\[readq-comic-zoom-in], \\[readq-comic-zoom-out] or C-wheel, and pan a zoomed page with
the arrow keys or by dragging it with the mouse.
\\{readq-comic-mode-map}"
  (setq-local cursor-type nil)
  ;; Like `image-mode': a page wider than the window scrolls sideways.
  (setq-local truncate-lines t)
  (setq-local auto-hscroll-mode nil)
  (setq-local revert-buffer-function (lambda (&rest _) (readq-comic--show)))
  (setq readq-comic--fit readq-comic-fit)
  (add-hook 'window-size-change-functions #'readq-comic--resized nil t))

(defun readq-comic--resized (window)
  "Fit the page again when WINDOW, showing a comic, changes size.
A zoomed page keeps its size instead.  What was in the middle of the
window stays there."
  (when (and (windowp window) (window-live-p window))
    (with-current-buffer (window-buffer window)
      (when (derived-mode-p 'readq-comic-mode)
        (when-let* (((/= readq-comic--zoom 1))
                    (width (car (readq-comic--image-size)))
                    (data (readq-comic--data readq-comic--page))
                    (fit (readq-comic--fit-image data (image-type-from-data data) window)))
          (setq readq-comic--zoom (/ width (float (max 1 (car (image-size fit t)))))))
        (if (zerop (window-old-body-pixel-width window))
            ;; A new window: nothing to keep in the middle.
            (readq-comic--show-keeping window '(0 . 0))
          (readq-comic--show-keeping
           window
           (cons (/ (window-old-body-pixel-width window) 2)
                 (/ (window-old-body-pixel-height window) 2))
           (cons (/ (window-body-width window t) 2)
                 (/ (window-body-height window t) 2))))))))

(defun readq-comic--data (page)
  "Return the image data of PAGE of this buffer's comic.
The last few pages are kept, so going back or resizing the window
does not read the archive again."
  (let* ((entry (nth (1- page) readq-comic--pages))
         (hit (assoc entry readq-comic--cache)))
    (if hit
        (cdr hit)
      (let ((data (readq-comic--page-data readq-comic--file entry)))
        (push (cons entry data) readq-comic--cache)
        (when (> (length readq-comic--cache) 4)
          (setcdr (nthcdr 3 readq-comic--cache) nil))
        data))))

(defun readq-comic--fit-image (data type win)
  "Return the image of DATA, of TYPE, fit to WIN, or nil if it can't be shown."
  (let ((w (and win (window-body-width win t)))
        (h (and win (window-body-height win t))))
    (and type (display-images-p)
         (apply #'create-image data type t
                (if (eq readq-comic--fit 'width)
                    (and w (list :width w))
                  (append (and w (list :max-width w))
                          (and h (list :max-height h))))))))

(defun readq-comic--show (&optional window)
  "Show the current page of the comic in this buffer.
Fit it to WINDOW, by default the selected window or one showing the
buffer, and show the page from its top there."
  (let* ((n (length readq-comic--pages))
         (page (max 1 (min (or readq-comic--page 1) n)))
         (inhibit-read-only t)
         (win (or window
                  (and (eq (window-buffer) (current-buffer)) (selected-window))
                  (get-buffer-window (current-buffer) t))))
    (setq readq-comic--page page)
    (erase-buffer)
    (if (zerop n)
        (insert "This comic has no pages that readq-comic can show.")
      (let* ((data (readq-comic--data page))
             (type (image-type-from-data data))
             (image (readq-comic--fit-image data type win)))
        (when (and image (/= readq-comic--zoom 1))
          ;; Zoom from the size the page has when it fits.
          (setq image (create-image data type t
                                    :width (max 1 (round (* readq-comic--zoom
                                                            (car (image-size image t))))))))
        (if image
            (insert-image image (format "[page %d]" page))
          (insert (format "[Page %d of %d: %s]" page n
                          (if type "this Emacs can't show images here"
                            "not an image Emacs can show"))))))
    (goto-char (point-min))
    (when win
      (set-window-vscroll win 0 t)
      (set-window-hscroll win 0))
    (setq mode-line-process (format " %d/%d%s" page n
                                    (if (= readq-comic--zoom 1) ""
                                      (format " %d%%" (round (* 100 readq-comic--zoom))))))
    (force-mode-line-update)))

(defun readq-comic-goto-page (page)
  "Show PAGE of the comic."
  (interactive (list (read-number (format "Page (1-%d): " (length readq-comic--pages))
                                  readq-comic--page)))
  (readq-comic-show-page page)
  (run-hooks 'readq-comic-page-change-hook))

(defun readq-comic-next-page (&optional n)
  "Show the next page, or the Nth next."
  (interactive "p")
  (let ((target (+ readq-comic--page (or n 1))))
    (if (> target (length readq-comic--pages))
        (message "Last page")
      (readq-comic-goto-page target))))

(defun readq-comic-previous-page (&optional n)
  "Show the previous page, or the Nth previous."
  (interactive "p")
  (let ((target (- readq-comic--page (or n 1))))
    (if (< target 1)
        (message "First page")
      (readq-comic-goto-page target))))

(defun readq-comic-first-page ()
  "Show the first page."
  (interactive)
  (readq-comic-goto-page 1))

(defun readq-comic-last-page ()
  "Show the last page."
  (interactive)
  (readq-comic-goto-page (length readq-comic--pages)))

(defun readq-comic--image-size ()
  "Return the size in pixels of the page shown, as (WIDTH . HEIGHT), or nil."
  (when-let* ((img (get-text-property (point-min) 'display)))
    (and (eq (car-safe img) 'image) (image-size img t))))

(defun readq-comic--image-height ()
  "Return the height in pixels of the page shown, or nil."
  (cdr (readq-comic--image-size)))

(defun readq-comic--x (win)
  "Return how far WIN is scrolled to the right, in pixels."
  (* (window-hscroll win) (window-font-width win)))

(defun readq-comic--scroll-to (win x y)
  "Scroll WIN to show the page from X, Y (pixels) on, within the page."
  (let* ((size (readq-comic--image-size))
         (col (window-font-width win))
         (max-x (max 0 (- (or (car size) 0) (window-body-width win t))))
         (max-y (max 0 (- (or (cdr size) 0) (window-body-height win t)))))
    ;; Horizontal scrolling is in columns: round up to see the right edge.
    (set-window-hscroll win (min (ceiling max-x col) (max 0 (round x col))))
    (set-window-vscroll win (min max-y (max 0 (round y))) t)))

(defun readq-comic--wider-p (win)
  "Return non-nil if the page shown is wider than WIN."
  (> (or (car (readq-comic--image-size)) 0) (window-body-width win t)))

(defun readq-comic-scroll-forward ()
  "Scroll down the page, or show the next page at its end.
On a page wider than the window, at the bottom go to the top of the
next strip to the right, as you read a zoomed page."
  (interactive)
  (let* ((win (selected-window))
         (size (readq-comic--image-size))
         (vscroll (window-vscroll win t))
         (body (window-body-height win t))
         (x (readq-comic--x win))
         (bw (window-body-width win t)))
    (cond
     ((and size (> (cdr size) (+ vscroll body)))
      (set-window-vscroll win (min (- (cdr size) body) (+ vscroll (round (* 0.9 body)))) t))
     ((and size (> (car size) (+ x bw)))
      (readq-comic--scroll-to win (+ x (round (* 0.9 bw))) 0))
     (t (readq-comic-next-page)))))

(defun readq-comic-scroll-backward ()
  "Scroll up the page, or show the previous page at its end.
On a page wider than the window, at the top go to the bottom of the
strip to the left."
  (interactive)
  (let* ((win (selected-window))
         (vscroll (window-vscroll win t))
         (body (window-body-height win t))
         (x (readq-comic--x win)))
    (cond
     ((> vscroll 0)
      (set-window-vscroll win (max 0 (- vscroll (round (* 0.9 body)))) t))
     ((> x 0)
      (readq-comic--scroll-to win (- x (round (* 0.9 (window-body-width win t))))
                              most-positive-fixnum))
     (t
      (readq-comic-previous-page)
      ;; Its end: the bottom right.
      (readq-comic--scroll-to win most-positive-fixnum most-positive-fixnum)))))

(defun readq-comic--pan (dx dy)
  "Move the view of the page by DX, DY fractions of the window."
  (let ((win (selected-window)))
    (readq-comic--scroll-to win
                            (+ (readq-comic--x win) (round (* dx (window-body-width win t))))
                            (+ (window-vscroll win t) (round (* dy (window-body-height win t)))))))

(defun readq-comic-scroll-down ()
  "Scroll down a little."
  (interactive)
  (readq-comic--pan 0 0.2))

(defun readq-comic-scroll-up ()
  "Scroll up a little."
  (interactive)
  (readq-comic--pan 0 -0.2))

(defun readq-comic-right (&optional n)
  "Pan right on a page wider than the window, else show the Nth next page."
  (interactive "p")
  (if (readq-comic--wider-p (selected-window))
      (readq-comic--pan 0.2 0)
    (readq-comic-next-page n)))

(defun readq-comic-left (&optional n)
  "Pan left on a page wider than the window, else show the Nth previous page."
  (interactive "p")
  (if (readq-comic--wider-p (selected-window))
      (readq-comic--pan -0.2 0)
    (readq-comic-previous-page n)))

(defun readq-comic-drag (event)
  "Pan the page by dragging it with the mouse, for mouse EVENT."
  (interactive "e")
  (let* ((win (posn-window (event-start event)))
         (start (posn-x-y (event-start event)))
         (x0 (readq-comic--x win))
         (y0 (window-vscroll win t))
         ev)
    (when (windowp win)
      (select-window win)
      ;; The page is one glyph: report every move, not only glyph changes.
      (let ((mouse-fine-grained-tracking t))
       (track-mouse
        (setq track-mouse 'dragging)
        (while (mouse-movement-p (setq ev (read-event)))
          (let ((pos (event-start ev)))
            (when (eq (posn-window pos) win)
              (let ((xy (posn-x-y pos)))
                (readq-comic--scroll-to win (- x0 (- (car xy) (car start)))
                                        (- y0 (- (cdr xy) (cdr start)))))))))))))

(defun readq-comic--set-zoom (zoom &optional event)
  "Zoom the page: ZOOM is a function from the zoom to the new zoom.
The zoom is relative to the page's fit.  The point of the page under
the mouse of EVENT, or else the middle of the window, stays where it is."
  (let* ((pos (and (consp event) (event-start event)))
         (win (if (windowp (posn-window pos)) (posn-window pos) (selected-window))))
    (with-selected-window win
      (setq readq-comic--zoom (max 0.25 (min 8.0 (funcall zoom readq-comic--zoom))))
      (readq-comic--show-keeping win (and pos (posn-x-y pos)))
      (message "Zoom %d%%" (round (* 100 readq-comic--zoom))))))

(defun readq-comic--show-keeping (win &optional at to)
  "Show the page again in WIN, moving the point of the page under AT to TO.
AT and TO are positions in WIN in pixels; AT is by default the middle
of WIN, and TO is by default AT."
  (let* ((size (readq-comic--image-size))
         (at (or at (cons (/ (window-body-width win t) 2) (/ (window-body-height win t) 2))))
         (to (or to at))
         ;; The point of the page under AT, as fractions of the page.
         (fx (and size (/ (+ (readq-comic--x win) (car at)) (float (max 1 (car size))))))
         (fy (and size (/ (+ (window-vscroll win t) (cdr at)) (float (max 1 (cdr size)))))))
    (readq-comic--show win)
    (when-let* ((new (and fx (readq-comic--image-size))))
      (readq-comic--scroll-to win (- (* fx (car new)) (car to))
                              (- (* fy (cdr new)) (cdr to))))))

(defun readq-comic-zoom-in (&optional event)
  "Zoom in by `readq-comic-zoom-step', on the mouse position for EVENT."
  (interactive (list last-nonmenu-event))
  (readq-comic--set-zoom (lambda (z) (* z readq-comic-zoom-step)) event))

(defun readq-comic-zoom-out (&optional event)
  "Zoom out by `readq-comic-zoom-step', on the mouse position for EVENT."
  (interactive (list last-nonmenu-event))
  (readq-comic--set-zoom (lambda (z) (/ z readq-comic-zoom-step)) event))

(defun readq-comic-zoom-reset ()
  "Fit the page again, as `readq-comic-fit-page' or `readq-comic-fit-width' set."
  (interactive)
  (readq-comic--set-zoom (lambda (_) 1.0)))

(defun readq-comic-fit-width ()
  "Make pages as wide as the window; scroll down them with SPC."
  (interactive)
  (setq readq-comic--fit 'width
        readq-comic--zoom 1.0)
  (readq-comic--show))

(defun readq-comic-fit-page ()
  "Show whole pages."
  (interactive)
  (setq readq-comic--fit 'page
        readq-comic--zoom 1.0)
  (readq-comic--show))

(defun readq-comic--open (file &optional other-window)
  "Show the comic FILE in a buffer of its own, or the buffer showing it.
With OTHER-WINDOW, in another window.  Return the buffer."
  (let* ((file (expand-file-name file))
         (buf (or (cl-find-if (lambda (b)
                                (let ((f (buffer-local-value 'readq-comic--file b)))
                                  (and f (readq-comic--same-file-p f file))))
                              (buffer-list))
                  (let ((pages (readq-comic--page-list file)))
                    (with-current-buffer (generate-new-buffer (file-name-nondirectory file))
                      (readq-comic-mode)
                      (setq readq-comic--file file
                            readq-comic--pages pages
                            default-directory (file-name-directory file))
                      (current-buffer))))))
    (if other-window (switch-to-buffer-other-window buf) (pop-to-buffer-same-window buf))
    (readq-comic--show)
    (run-hooks 'readq-comic-open-hook)
    buf))

;;;###autoload
(defun readq-comic-open (file &optional other-window)
  "Show the comic (CBZ, CBR or CB7) FILE, one page at a time.
With OTHER-WINDOW, in another window.  If a buffer shows FILE already,
go to it.  Return the buffer."
  (interactive (list (read-file-name "Comic: " nil nil t nil
                                     (lambda (f) (or (file-directory-p f)
                                                     (string-match-p readq-comic-file-re f))))))
  (readq-comic--open file other-window))

;;;; For other programs

(defun readq-comic--same-file-p (a b)
  "Return non-nil when the file names A and B are the same file.
File names are compared case-insensitively on Windows."
  (let ((a (file-truename (expand-file-name a)))
        (b (file-truename (expand-file-name b))))
    (if (memq system-type '(windows-nt ms-dos cygwin))
        (eq t (compare-strings a nil nil b nil nil t))
      (string= a b))))

(defun readq-comic-current-file ()
  "Return the comic file shown in this buffer, or nil."
  readq-comic--file)

(defun readq-comic-current-page ()
  "Return the page shown in this buffer, from 1."
  readq-comic--page)

(defun readq-comic-page-count ()
  "Return the number of pages of the comic in this buffer."
  (length readq-comic--pages))

(defun readq-comic-show-page (page)
  "Show PAGE of the comic in this buffer, without running the page hook."
  (setq readq-comic--page (max 1 (min page (length readq-comic--pages))))
  (readq-comic--show))

(defun readq-comic-current-image ()
  "Return the image data of the page shown in this buffer, a unibyte string."
  (readq-comic--data readq-comic--page))

(provide 'readq-comic)
;;; readq-comic.el ends here
