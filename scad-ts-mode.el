;;; scad-ts-mode.el --- Tree-sitter major mode for OpenSCAD -*- lexical-binding: t; -*-

;; Copyright (C) Karim Aziiev <karim.aziiev@gmail.com>

;; Author: Karim Aziiev <karim.aziiev@gmail.com>
;; URL: https://github.com/KarimAziev/scad-ts-mode
;; Version: 0.1.0
;; Keywords: languages
;; Package-Requires: ((emacs "29.1") (scad-mode "97.0"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Tree-sitter powered major mode for OpenSCAD files.

;;; Code:

(require 'cc-mode)
(eval-when-compile
  (require 'cc-langs)
  (require 'cc-fonts)
  (require 'cl-lib))
(require 'scad-mode)
(require 'treesit)

(declare-function treesit-parser-create "treesit.c")
(declare-function treesit-node-child-by-field-name "treesit.c")
(declare-function treesit-node-text "treesit.c")

(add-to-list
 'treesit-language-source-alist
 '(openscad "https://github.com/openscad/tree-sitter-openscad"))

(defvar scad-ts-mode--syntax-table
  (let ((table (make-syntax-table)))
    (c-populate-syntax-table table)
    table)
  "Syntax table for `scad-ts-mode'.")


(defun scad-ts-mode--buffer-root-node ()
  "Return the root node of a parse tree in the current buffer."
  (condition-case nil
      (treesit-buffer-root-node 'openscad)
    (treesit-no-parser
     (treesit-parser-create 'openscad)
     (treesit-buffer-root-node 'openscad))))

(defun scad-ts-mode--imported-paths (&optional type)
  "Extract imported include/use file paths, optionally filtering by statement type.

Optional argument TYPE is a tree-sitter node type symbol, or nil by
default to match `include_statement' and `use_statement'."
  (let ((statements
         (treesit-query-capture
          (scad-ts-mode--buffer-root-node)
          (if type
              `((,type (include_path) @path))
            '((include_statement (include_path) @path)
              (use_statement (include_path) @path))))))
    (mapcar (pcase-lambda (`(,_ . ,node))
              (let ((txt (treesit-node-text node t)))
                (substring-no-properties txt 1 (1- (length
                                                    txt)))))
            statements)))

(defun scad-ts-mode--variable-declarations ()
  (let ((statements
         (treesit-query-capture
          (scad-ts-mode--buffer-root-node)
          '((var_declaration (assignment (identifier)) @identifier)))))
    (mapcar (pcase-lambda (`(,_ . ,node))
              (let ((txt (treesit-node-text node t)))
                (cons txt node)))
            statements)))



(defvar scad-ts-mode--font-lock-settings
  (treesit-font-lock-rules
   :language 'openscad
   :feature 'comment
   '((line_comment) @font-lock-comment-face
     (block_comment) @font-lock-comment-face)
   :language 'openscad
   :feature 'string
   :override t
   '((string) @font-lock-string-face
     (escape_sequence) @font-lock-escape-face)
   :language 'openscad
   :feature 'number
   '([(integer)
      (float)]
     @font-lock-number-face)
   :language 'openscad
   :feature 'keyword
   '(["module" "function" "let" "assign" "use" "include" "each"
      "for" "intersection_for" "if" "else" "assert" "echo"]
     @font-lock-keyword-face)
   :language 'openscad
   :feature 'operator
   '(["||" "&&" "==" "!=" "<" ">" "<=" ">=" "+" "-" "*" "/" "%" "^" "!" ":" "="
      "?"]
     @font-lock-operator-face)
   :language 'openscad
   :feature 'bracket
   '((["{" "}" "(" ")" "[" "]"]) @font-lock-bracket-face)
   :language 'openscad
   :feature 'delimiter
   '(([";" "," "."]) @font-lock-delimiter-face)
   :language 'openscad
   :feature 'constant
   '((boolean) @font-lock-constant-face
     (undef) @font-lock-constant-face
     ((identifier) @font-lock-constant-face
      (:match "^PI$" @font-lock-constant-face)))
   :language 'openscad
   :feature 'builtin
   `(((module_call name: (identifier) @font-lock-builtin-face)
      (:match
       "\\`\\(circle\\|color\\|cube\\|cylinder\\|difference\\|hull\\|intersection\\|linear_extrude\\|minkowski\\|mirror\\|multmatrix\\|offset\\|polygon\\|polyhedron\\|projection\\|resize\\|rotate\\|rotate_extrude\\|scale\\|sphere\\|square\\|surface\\|text\\|translate\\|union\\|echo\\)\\'"
       @font-lock-builtin-face))
     (special_variable) @font-lock-builtin-face)
   :language 'openscad
   :feature 'function
   '((function_item name: (identifier) @font-lock-function-name-face)
     (function_call name: (identifier) @font-lock-function-call-face)
     (module_item name: (identifier) @font-lock-function-name-face)
     (module_call name: (identifier) @font-lock-function-call-face))
   :language 'openscad
   :feature 'variable
   '((parameter (identifier) @font-lock-variable-name-face)
     (parameter (assignment name: (identifier) @font-lock-variable-name-face))
     (assignment name: (identifier) @font-lock-variable-name-face)
     (dot_index_expression index: (identifier) @font-lock-property-name-face)
     (identifier) @font-lock-variable-name-face))
  "Tree-sitter font-lock settings for `scad-ts-mode'.")

(defvar scad-ts-mode--font-lock-feature-list
  '((comment)
    (string number)
    (keyword builtin constant)
    (function variable operator delimiter bracket))
  "Font-lock feature list for `scad-ts-mode'.")

(defvar scad-ts-mode--defun-type-regexp
  (rx bos (or "module_item" "function_item") eos)
  "Regexp describing defun-like nodes.")

(defvar scad-ts-mode--imenu-settings
  '(( "Module" "\\`module_item\\'" nil nil)
    ( "Function" "\\`function_item\\'" nil nil))
  "Imenu configuration for `scad-ts-mode'.")

(defun scad-ts-mode--defun-name (node)
  "Return the defun name of NODE."
  (when (string-match-p scad-ts-mode--defun-type-regexp
                        (treesit-node-type node))
    (treesit-node-text (treesit-node-child-by-field-name node "name") t)))

(defun scad-ts-mode--outline-predicate (node)
  "Return non-nil when NODE should start an outline entry."
  (and (string-match-p scad-ts-mode--defun-type-regexp
                       (treesit-node-type node))
       (treesit-node-top-level node scad-ts-mode--defun-type-regexp)))

;;;###autoload
(define-derived-mode scad-ts-mode scad-mode "OpenSCAD"
  "Major mode for editing OpenSCAD using tree-sitter."
  :group 'openscad
  :after-hook (c-update-modeline)
  :syntax-table scad-ts-mode--syntax-table
  (when (fboundp 'treesit-ensure-installed)
    (unless (treesit-ensure-installed 'openscad)
      (error "Tree-sitter grammar for OpenSCAD isn't available")))
  (c-initialize-cc-mode t)
  (c-init-language-vars scad-ts-mode)
  (c-common-init 'scad-ts-mode)
  (c-set-offset 'cpp-macro 0 nil)
  (c-run-mode-hooks 'c-mode-common-hook)
  (setq treesit-primary-parser (treesit-parser-create 'openscad))
  ;; Comments.
  (setq-local comment-start "// ")
  (setq-local comment-end "")
  (setq-local comment-start-skip "//+ *")
  ;; Indentation.
  (setq-local indent-tabs-mode nil)
  ;; Font-lock.
  (setq-local treesit-font-lock-settings scad-ts-mode--font-lock-settings)
  (setq-local treesit-font-lock-feature-list
              scad-ts-mode--font-lock-feature-list)
  ;; Navigation.
  (setq-local treesit-defun-type-regexp scad-ts-mode--defun-type-regexp)
  (setq-local treesit-defun-name-function #'scad-ts-mode--defun-name)
  ;; Imenu and outline.
  (setq-local treesit-simple-imenu-settings scad-ts-mode--imenu-settings)
  (setq-local treesit-outline-predicate #'scad-ts-mode--outline-predicate)
  (treesit-major-mode-setup))

(put 'scad-ts-mode 'c-mode-prefix "scad-ts-")

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.scad\\'" . scad-ts-mode))

(provide 'scad-ts-mode)
;;; scad-ts-mode.el ends here