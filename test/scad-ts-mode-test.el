;;; scad-ts-mode-test.el --- Fontification tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with an installed OpenSCAD grammar:
;; emacs -Q --batch -L . -l test/scad-ts-mode-test.el \
;;   -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'scad-ts-mode)

(defmacro scad-ts-mode-test--with-source (source &rest body)
  "Fontify SOURCE at each supported level, then evaluate BODY."
  (declare (indent 1) (debug t))
  `(progn
     (skip-unless (treesit-language-available-p 'openscad))
     (dolist (treesit-font-lock-level '(2 3 4))
       (with-temp-buffer
         (insert ,source)
         (delay-mode-hooks (scad-ts-mode))
         (font-lock-ensure)
         (should-not (treesit-node-check
                      (treesit-buffer-root-node 'openscad) 'has-error))
         ,@body))))

(defun scad-ts-mode-test--face (text &optional offset)
  "Return the face at OFFSET within the first occurrence of TEXT."
  (save-excursion
    (goto-char (point-min))
    (search-forward text)
    (get-text-property (+ (- (point) (length text)) (or offset 0)) 'face)))

(ert-deftest scad-ts-mode-test-assert-statement ()
  "An assertion must not color its arguments or following statement."
  (scad-ts-mode-test--with-source
      (concat "assert(check(value), \"valid\");\n"
              "assert(is_num(value), \"number required\");\n"
              "after = 42;\n")
    (should (eq (scad-ts-mode-test--face "assert") 'font-lock-keyword-face))
    (should (eq (scad-ts-mode-test--face "assert(is_num") 'font-lock-keyword-face))
    (should (eq (scad-ts-mode-test--face "valid") 'font-lock-string-face))
    (should (eq (scad-ts-mode-test--face "is_num") 'font-lock-builtin-face))
    (should (eq (scad-ts-mode-test--face "number required") 'font-lock-string-face))
    (should-not (scad-ts-mode-test--face "value"))
    (should (eq (scad-ts-mode-test--face "after") 'font-lock-variable-name-face))
    (should-not (eq (scad-ts-mode-test--face ";") 'font-lock-keyword-face))))

(ert-deftest scad-ts-mode-test-assert-module-body ()
  "An assertion must not color its child module or block."
  (scad-ts-mode-test--with-source
      "module example(value) { assert(value > 0, \"positive\") cube(value); }\n"
    (should (eq (scad-ts-mode-test--face "assert") 'font-lock-keyword-face))
    (should (eq (scad-ts-mode-test--face "positive") 'font-lock-string-face))
    (should (eq (scad-ts-mode-test--face "cube") 'font-lock-builtin-face))
    (should-not (scad-ts-mode-test--face "cube(value)" 5))))

(ert-deftest scad-ts-mode-test-assert-expression ()
  "Chained assertions must preserve faces throughout the tail expression."
  (scad-ts-mode-test--with-source
      (concat "function example(value) =\n"
              "  assert(is_num(value), \"number required\")\n"
              "  assert(value > 0, \"positive\")\n"
              "  let(first = value + 1, second = first * 2)\n"
              "  [second, assert(value < 10, \"small\") value];\n")
    (should (eq (scad-ts-mode-test--face "assert") 'font-lock-keyword-face))
    (should (eq (scad-ts-mode-test--face "assert(value >") 'font-lock-keyword-face))
    (should (eq (scad-ts-mode-test--face "assert(value <") 'font-lock-keyword-face))
    (should (eq (scad-ts-mode-test--face "number required") 'font-lock-string-face))
    (should (eq (scad-ts-mode-test--face "positive") 'font-lock-string-face))
    (should (eq (scad-ts-mode-test--face "small") 'font-lock-string-face))
    (should (eq (scad-ts-mode-test--face "let") 'font-lock-keyword-face))
    (dolist (text '("first" "second" "value];"))
      (should-not (eq (scad-ts-mode-test--face text) 'font-lock-keyword-face)))
    (when (>= treesit-font-lock-level 3)
      (should (eq (scad-ts-mode-test--face "1") 'font-lock-number-face))
      (should (eq (scad-ts-mode-test--face "2") 'font-lock-number-face)))))

(ert-deftest scad-ts-mode-test-assert-partial-refontification ()
  "Refontifying part of an assertion must preserve full-buffer faces."
  (scad-ts-mode-test--with-source
      (concat "function example(value) =\n"
              "  assert(value > 0, \"positive\")\n"
              "  let(first = value + 1,\n"
              "      second = min(first * 2, value))\n"
              "  second;\n")
    (let ((before (buffer-substring (point-min) (point-max))))
      (goto-char (point-min))
      (forward-line 3)
      (treesit-font-lock-fontify-region (point-min) (point))
      (treesit-font-lock-fontify-region (point) (point-max))
      (dotimes (index (length before))
        (should (equal (get-text-property index 'face before)
                       (get-text-property (1+ index) 'face)))))
    (should (eq (scad-ts-mode-test--face "positive") 'font-lock-string-face))
    (should-not (eq (scad-ts-mode-test--face "second") 'font-lock-keyword-face))))

(provide 'scad-ts-mode-test)
;;; scad-ts-mode-test.el ends here
