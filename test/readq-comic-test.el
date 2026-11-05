;;; readq-comic-test.el --- Tests for readq-comic -*- lexical-binding: t; -*-

;; Run with:
;;   emacs -Q --batch -L . -l test/readq-comic-test.el \
;;     -f ert-run-tests-batch-and-exit
;; Each archiver's tests run when it is installed (7z, bsdtar, unar, unzip).

;;; Code:

(require 'ert)
(require 'readq-comic)

(defconst readq-comic-test--fixtures
  (expand-file-name "fixtures" (file-name-directory
                                (or load-file-name buffer-file-name))))

(defvar readq-comic-test--dir nil
  "The temporary directory of the test running.")

(defconst readq-comic-test--pages
  '("Chapter 1/page1.png" "Chapter 1/page2.png" "Chapter 1/page10.png" "cover.png")
  "The pages of test/fixtures/comic.cbz in reading order.")

(defmacro readq-comic-test--with-dir (&rest body)
  "Run BODY in a temporary directory, then kill the comics it opened."
  (declare (indent 0))
  `(let ((readq-comic-test--dir (make-temp-file "readq-comic-test" t))
         (readq-comic-program nil))
     (unwind-protect (progn ,@body)
       (dolist (b (buffer-list))
         (when (with-current-buffer b (derived-mode-p 'readq-comic-mode))
           (kill-buffer b)))
       (delete-directory readq-comic-test--dir t))))

(defun readq-comic-test--copy (name &optional as)
  "Copy fixture NAME into the test directory (as AS) and return its path."
  (let ((dest (expand-file-name (or as name) readq-comic-test--dir)))
    (copy-file (expand-file-name name readq-comic-test--fixtures) dest t)
    dest))

(defun readq-comic-test--touch (name)
  "Create the empty file NAME in the test directory and return its path."
  (let ((file (expand-file-name name readq-comic-test--dir)))
    (make-directory (file-name-directory file) t)
    (write-region "" nil file nil 'silent)
    file))

(defun readq-comic-test--program (name)
  "Return the archiver NAME if installed (bsdtar: a tar that is bsdtar)."
  (let ((p (executable-find name)))
    (and p (or (not (equal name "bsdtar")) (readq-comic--bsdtar-p p)) p)))

(defmacro readq-comic-test--each-program (names &rest body)
  "Run BODY with `readq-comic-program' set to each of NAMES installed."
  (declare (indent 1))
  `(let ((found nil))
     (dolist (name ,names)
       (when-let ((p (readq-comic-test--program name)))
         (setq found t)
         (let ((readq-comic-program p))
           ,@body)))
     (unless found (ert-skip "No archiver installed"))))

;;;; Archives

(ert-deftest readq-comic-test-archive-kind ()
  (readq-comic-test--with-dir
    (should (eq (readq-comic--kind (readq-comic-test--copy "comic.cbz")) 'zip))
    (should (eq (readq-comic--kind (readq-comic-test--copy "comic.cb7")) '7z))
    ;; A .cbr is often a ZIP renamed: what counts is its contents.
    (should (eq (readq-comic--kind (readq-comic-test--copy "comic.cbz" "renamed.cbr")) 'zip))
    (let ((rar (expand-file-name "real.cbr" readq-comic-test--dir)))
      (let ((coding-system-for-write 'no-conversion))
        (with-temp-file rar (set-buffer-multibyte nil) (insert "Rar!\032\007\001\000rest")))
      (should (eq (readq-comic--kind rar) 'rar)))
    (should-not (readq-comic--kind (readq-comic-test--touch "plain.cbz")))))

(ert-deftest readq-comic-test-tool-kinds ()
  (should (eq (readq-comic--tool-kind "C:/Program Files/7-Zip/7z.exe") '7z))
  (should (eq (readq-comic--tool-kind "/usr/bin/7za") '7z))
  (should (eq (readq-comic--tool-kind "C:/Windows/System32/tar.exe") 'bsdtar))
  (should (eq (readq-comic--tool-kind "/usr/bin/bsdtar") 'bsdtar))
  (should (eq (readq-comic--tool-kind "unzip") 'unzip))
  (should (eq (readq-comic--tool-kind "C:/tools/unar.exe") 'unar))
  (should (eq (readq-comic--tool-kind "/usr/bin/lsar") 'unar))
  (should (eq (readq-comic--tool-kind "UnRAR.exe") 'unrar)))

(ert-deftest readq-comic-test-pages-cbz ()
  (readq-comic-test--with-dir
    (let ((file (readq-comic-test--copy "comic.cbz" "My Comic [1].cbz")))
      (readq-comic-test--each-program '("7z" "bsdtar" "unar" "unzip")
        ;; Images only, without macOS's leftovers, in natural order.
        (should (equal (readq-comic--page-list file) readq-comic-test--pages))
        (should (= (readq-comic-count-pages file) 4))
        (let ((data (readq-comic--page-data file "Chapter 1/page1.png")))
          (should (= (length data) 89))
          (should-not (multibyte-string-p data))
          (should (eq (image-type-from-data data) 'png)))
        (should (= (length (readq-comic--page-data file "cover.png")) 85))))))

(ert-deftest readq-comic-test-pages-cb7-and-renamed ()
  (readq-comic-test--with-dir
    (let ((cb7 (readq-comic-test--copy "comic.cb7"))
          (cbr (readq-comic-test--copy "comic.cbz" "renamed.cbr")))
      (readq-comic-test--each-program '("7z" "bsdtar" "unar")
        (should (equal (readq-comic--page-list cb7)
                       (remove "info.txt" readq-comic-test--pages)))
        (should (= (length (readq-comic--page-data cb7 "Chapter 1/page2.png")) 86))
        (should (equal (readq-comic--page-list cbr) readq-comic-test--pages)))
      ;; unzip reads the ZIP whatever its name, but not 7z.
      (when-let ((unzip (readq-comic-test--program "unzip")))
        (let ((readq-comic-program unzip))
          (should (equal (readq-comic--page-list cbr) readq-comic-test--pages))
          (should-error (readq-comic--page-list cb7) :type 'user-error))))))

(ert-deftest readq-comic-test-names-not-ascii-or-wildcards ()
  ;; café/页 [1].png and café/页 [2].png: brackets are wildcards to
  ;; bsdtar, unzip and unar.
  (readq-comic-test--with-dir
    (let ((file (readq-comic-test--copy "comic-unicode.cbz")))
      (readq-comic-test--each-program '("7z" "bsdtar" "unar" "unzip")
        (should (equal (readq-comic--page-list file)
                       '("café/页 [1].png" "café/页 [2].png")))
        (should (= (length (readq-comic--page-data file "café/页 [2].png")) 85))))))

(ert-deftest readq-comic-test-unar-with-lsar ()
  ;; unar lists with the lsar beside it, whichever of the two is set.
  (skip-unless (and (executable-find "unar") (executable-find "lsar")))
  (readq-comic-test--with-dir
    (let ((file (readq-comic-test--copy "comic.cbz")))
      (dolist (prog (list (executable-find "unar") (executable-find "lsar")))
        (let ((readq-comic-program prog)
              (readq-comic--unar-entries-cache nil))
          (should (equal (readq-comic--page-list file) readq-comic-test--pages))
          (should (= (length (readq-comic--page-data file "cover.png")) 85)))))))

(ert-deftest readq-comic-test-finding-a-program ()
  (readq-comic-test--with-dir
    (let ((zip (readq-comic-test--copy "comic.cbz"))
          (cb7 (readq-comic-test--copy "comic.cb7"))
          (found '("unzip")))
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (name &rest _) (and (member name found) (concat "/bin/" name))))
                ((symbol-function 'file-executable-p) #'ignore))
        (should (equal (readq-comic--program zip) '(unzip . "/bin/unzip")))
        (should-error (readq-comic--program cb7) :type 'user-error)
        ;; 7-Zip comes first, and reads everything.
        (setq found '("unzip" "7z"))
        (should (equal (readq-comic--program zip) '(7z . "/bin/7z")))
        (should (equal (readq-comic--program cb7) '(7z . "/bin/7z")))
        ;; unar reads everything; it comes before unzip.
        (setq found '("unzip" "unar"))
        (should (equal (readq-comic--program zip) '(unar . "/bin/unar")))
        (should (equal (readq-comic--program cb7) '(unar . "/bin/unar")))
        ;; A tar that is not bsdtar (GNU tar) cannot read ZIP or RAR.
        (setq found '("tar"))
        (cl-letf (((symbol-function 'readq-comic--bsdtar-p) #'ignore))
          (should-error (readq-comic--program zip) :type 'user-error))
        (cl-letf (((symbol-function 'readq-comic--bsdtar-p) (lambda (_) t)))
          (should (equal (readq-comic--program zip) '(bsdtar . "/bin/tar"))))))))

(ert-deftest readq-comic-test-commands ()
  ;; The arguments each archiver gets, unrar's included.
  (readq-comic-test--with-dir
    (let ((rar (expand-file-name "real.cbr" readq-comic-test--dir))
          calls)
      (let ((coding-system-for-write 'no-conversion))
        (with-temp-file rar (set-buffer-multibyte nil) (insert "Rar!\032\007\000")))
      (cl-letf (((symbol-function 'readq-comic--run)
                 (lambda (tool &rest args) (push (cons (car tool) args) calls)
                   (if (member "lb" args) "b/2.jpg\nb/1.jpg\nnotes.txt\n" "data"))))
        (let ((readq-comic-program "/bin/unrar"))
          (should (equal (readq-comic--page-list rar) '("b/1.jpg" "b/2.jpg")))
          (readq-comic--page-data rar "b/1.jpg")
          (should (equal (car calls) (list 'unrar "p" "-inul" "--" rar "b/1.jpg"))))
        (let ((readq-comic-program "/bin/unzip")
              (zip (readq-comic-test--copy "comic.cbz")))
          ;; unzip's wildcards match only themselves.
          (readq-comic--page-data zip "a[1]*.png")
          (should (equal (car calls) (list 'unzip "-p" "--" zip "a?1??.png"))))))))

(ert-deftest readq-comic-test-archiver-failure ()
  (readq-comic-test--with-dir
    (let ((bad (readq-comic-test--touch "broken.cbz")))
      (let ((coding-system-for-write 'no-conversion))
        (with-temp-file bad (set-buffer-multibyte nil) (insert "PK\003\004broken")))
      (readq-comic-test--each-program '("7z" "bsdtar" "unar" "unzip")
        (should-error (readq-comic--page-list bad))
        (should-not (readq-comic-count-pages bad))))))

;;;; Viewing

(ert-deftest readq-comic-test-pages ()
  (skip-unless (cl-some #'readq-comic-test--program '("7z" "bsdtar" "unzip")))
  (readq-comic-test--with-dir
    (let ((file (readq-comic-test--copy "comic.cbz")))
      (readq-comic-open file)
      (should (derived-mode-p 'readq-comic-mode))
      (readq-comic-goto-page 99)
      (should (= readq-comic--page 4))
      (readq-comic-previous-page 2)
      (should (= readq-comic--page 2))
      (readq-comic-first-page)
      (readq-comic-previous-page)
      (should (= readq-comic--page 1))
      (readq-comic-fit-width)
      (should (eq readq-comic--fit 'width)))))

(ert-deftest readq-comic-test-hooks-and-api ()
  (skip-unless (cl-some #'readq-comic-test--program '("7z" "bsdtar" "unzip")))
  (readq-comic-test--with-dir
    (let* ((file (readq-comic-test--copy "comic.cbz"))
           (opened 0) (turned nil)
           (readq-comic-open-hook (list (lambda () (cl-incf opened))))
           (readq-comic-page-change-hook
            (list (lambda () (push (readq-comic-current-page) turned)))))
      (let ((buf (readq-comic-open file)))
        (should (= opened 1))
        (should (equal (readq-comic-current-file) file))
        (should (= (readq-comic-page-count) 4))
        ;; Turning pages runs the hook; showing one for a program doesn't.
        (readq-comic-next-page)
        (readq-comic-last-page)
        (should (equal turned '(4 2)))
        (readq-comic-show-page 2)
        (should (= (readq-comic-current-page) 2))
        (should (equal turned '(4 2)))
        (should (= (length (readq-comic-current-image)) 86))
        ;; Opening it again goes to its buffer.
        (should (eq (readq-comic-open file) buf))
        (should (= opened 2))))))

(ert-deftest readq-comic-test-zoom ()
  (skip-unless (cl-some #'readq-comic-test--program '("7z" "bsdtar" "unzip")))
  (readq-comic-test--with-dir
    (let ((file (readq-comic-test--copy "comic.cbz")))
      (readq-comic-open file)
      (should (eq (key-binding "+") #'readq-comic-zoom-in))
      (should (eq (key-binding [C-wheel-up]) #'readq-comic-zoom-in))
      (readq-comic-zoom-in)
      (readq-comic-zoom-in)
      (should (= readq-comic--zoom (* 1.25 1.25)))
      (should (equal mode-line-process " 1/4 156%"))
      ;; The zoom stays as you turn pages.
      (readq-comic-next-page)
      (should (= readq-comic--zoom (* 1.25 1.25)))
      (readq-comic-zoom-out)
      (should (= readq-comic--zoom 1.25))
      (readq-comic-zoom-reset)
      (should (= readq-comic--zoom 1.0))
      (should (equal mode-line-process " 2/4"))
      ;; It stays within limits.
      (dotimes (_ 30) (readq-comic-zoom-in))
      (should (= readq-comic--zoom 8.0))
      (dotimes (_ 30) (readq-comic-zoom-out))
      (should (= readq-comic--zoom 0.25))
      ;; Choosing a fit zooms back to it.
      (readq-comic-fit-width)
      (should (= readq-comic--zoom 1.0))
      ;; Arrows turn pages when the page fits across the window.
      (readq-comic-right)
      (should (= readq-comic--page 3))
      (readq-comic-left)
      (should (= readq-comic--page 2)))))

(provide 'readq-comic-test)
;;; readq-comic-test.el ends here
