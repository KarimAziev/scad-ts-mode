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

(require 'treesit)

(defgroup scad-ts nil
  "A major mode for editing OpenSCAD code."
  :link '(url-link :tag "Website" "https://github.com/KarimAziev/scad-ts-mode")
  :link '(emacs-library-link :tag "Library Source" "scad-ts-mode.el")
  :group 'languages
  :prefix "scad-ts")

(defcustom scad-ts-mode-functions '("acos" "asin" "atan" "atan2" "abs" "cos"
                                    "ceil" "cross" "concat" "chr" "dxf_dim"
                                    "dxf_cross" "exp" "floor" "is_undef"
                                    "is_list" "is_num" "is_bool" "is_string"
                                    "is_function" "log" "ln" "lookup" "len"
                                    "min" "max" "norm" "ord" "pow" "rands"
                                    "round" "sin" "sign" "sqrt" "str" "search"
                                    "tan" "version" "version_num")
  "List of function names used for tree-sitter font-lock highlighting."
  :group 'scad-ts
  :type '(repeat string))

(defcustom scad-ts-mode-modules '("children" "cube" "cylinder" "circle" "color"
                                  "difference" "echo" "group" "hull"
                                  "intersection" "import" "linear_extrude"
                                  "mirror" "multmatrix" "minkowski" "offset"
                                  "polyhedron" "polygon" "projection"
                                  "parent_module" "rotate" "render"
                                  "rotate_extrude" "resize" "roof" "sphere"
                                  "square" "scale" "surface" "translate" "text"
                                  "union")
  "List of module names used for syntax highlighting.

A list of OpenSCAD module names to highlight as built-in modules.

Each element should be a string naming a module, without parentheses or
arguments.

Changing the list updates the tree-sitter font-lock settings used for
highlighting."
  :group 'scad-ts
  :type '(repeat string))

(defcustom scad-ts-indent-offset 2
  "Number of spaces for each indentation step in `scat-ts-mode'."
  :type 'natnum
  :safe 'natnump
  :group 'scad-ts)


(defcustom scad-ts-mode-openscad-command "openscad"
  "Command name or path used to run OpenSCAD for Flymake checks.

Command used to invoke the OpenSCAD executable.

The value should be a string naming an executable found in the variable
`exec-path', or an absolute file name.

Used by the Flymake backend to run OpenSCAD with \"-o\" to generate an
AST file for diagnostics."
  :group 'scad-ts
  :type 'string)

(defcustom scad-ts-mode-openscad-extra-args nil
  "Extra command-line arguments appended to the OpenSCAD flymake command.

Extra command line arguments passed to the OpenSCAD executable.

The value is a list of strings, each string being one argument.

The arguments are appended after the default arguments used for
generating an AST file during Flymake runs.

Example value: \\='(\"--backend=Manifold\" \"--enable=roof\")"
  :type '(repeat string))

(defcustom scad-ts-mode-debug nil
  "Whether to allow debug logging.

Debug messages are logged to the *scad-ts-mode-debug* buffer.

If t, all messages will be logged.
If a number, all messages will be logged, as well shown via `message'.
If a list, it is a list of the types of messages to be logged."
  :group 'scad-ts-mode
  :type '(radio
          (const :tag "none" nil)
          (const :tag "all" t)
          (checklist :tag "custom"
           (integer :tag "Allow echo message buffer")
           (const :tag "Flymake" flymake)
           (symbol :tag "Other"))))


(defun scad-ts-mode--debug (tag &rest args)
  "Log debug messages based on the variable `scad-ts-mode-debug'.

Argument TAG is a symbol or string used to identify the debug message.

Remaining arguments ARGS are format string followed by objects to format,
similar to `format' function arguments."
  (when (and scad-ts-mode-debug
             (or (eq scad-ts-mode-debug t)
                 (numberp scad-ts-mode-debug)
                 (and (listp scad-ts-mode-debug)
                      (memq tag scad-ts-mode-debug))))
    (with-current-buffer (get-buffer-create "*scad-ts-mode-debug*")
      (goto-char (point-max))
      (insert (format "%s" tag) " -> " (apply #'format args) "\n")
      (when (numberp scad-ts-mode-debug)
        (apply #'message args)))))


(defconst scad-ts-mode--import-regexp
  "\\_<\\(import\\)\\_>[\s]*("
  "Regular expression matching SCAD import statements.")

(add-to-list
 'treesit-language-source-alist
 '(openscad "https://github.com/openscad/tree-sitter-openscad"))

(defvar scad-ts-mode-syntax-table
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


(defconst scad-ts--import-call-query
  '(
    ;; import("path")
    (module_call
     name: (identifier) @fn
     arguments: (arguments (string) @path)
     (:match "import" @fn))
    ;; import(file="path", ...)
    (module_call
     name: (identifier) @fn
     arguments: (arguments
                 (assignment
                  name: (identifier) @kw
                  value: (string) @path))
     (:match "import" @fn)
     (:match "file" @kw)))
  "Tree-sitter query capturing import() file path strings.")




(defun scad-ts-mode--import-calls ()
  "Return a list of file paths from OpenSCAD import(...) calls."
  (let* ((caps (treesit-query-capture
                (scad-ts-mode--buffer-root-node)
                scad-ts--import-call-query))
         (strings
          (cl-loop for (cap . node) in caps
                   when (eq cap 'path)
                   collect (treesit-node-text node t))))
    ;; captured (string) includes quotes -> strip them
    (mapcar (lambda (s)
              (string-trim s "\"" "\""))
            strings)))


(defun scad-ts-mode--variable-declarations ()
  "Collect variable declaration identifiers and return them paired with nodes."
  (let ((statements
         (treesit-query-capture
          (scad-ts-mode--buffer-root-node)
          '((var_declaration (assignment (identifier) @identifier))))))
    (mapcar (pcase-lambda (`(,_ . ,node))
              (let ((txt (treesit-node-text node t)))
                (cons txt node)))
            statements)))

(defun scad-ts-mode--local-variable-declarations ()
  "Collect local variable names and nodes from let-block assignment identifiers."
  (let ((statements
         (treesit-query-capture
          (scad-ts-mode--buffer-root-node)
          '((let_block (assignments)  @identifier)))))
    (mapcar (pcase-lambda (`(,_ . ,node))
              (let ((txt (treesit-node-text node t)))
                (cons txt node)))
            statements)))

(defun scad-ts-mode--match-any (items)
  "Build a regexp matching exactly any string or symbol name in ITEMS.

Argument ITEMS is a list of strings or symbols converted to strings."
  (concat "\\`" (regexp-opt (mapcar
                             (lambda (it)
                               (if (symbolp it)
                                   (symbol-name it)
                                 it))
                             items))
          "\\'"))

(defun scad-ts-mode--make-settings (modules functions)
  "Build tree-sitter font-lock rules for OpenSCAD using MODULES and FUNCTIONS.

Argument MODULES is a list of module names used to match builtins.

Argument FUNCTIONS is a list of function names used to match builtins."
  (apply #'treesit-font-lock-rules
         `(:language openscad
           :feature comment
           ([(line_comment)
             (block_comment)
             (transform_chain (modifier "*"))]
            @font-lock-comment-face)
           :language openscad
           :feature comment
           ((modifier ["*" "!" "#" "%"]
             @font-lock-comment-face))
           :language openscad
           :feature definition
           ([(function_item name: (_)
              @font-lock-function-name-face)
             (module_item name: (_)
              @font-lock-function-name-face)
             (var_declaration (assignment name: (_)
                               @font-lock-variable-name-face))
             (parameters
              (parameter
               (assignment name: (_)
                @font-lock-variable-name-face)))
             (parameters
              (parameter
               (identifier) @font-lock-variable-name-face))])
           :language openscad
           :feature builtin
           :override t
           (((special_variable "$" (_))
             @font-lock-builtin-face
             (:match ,(scad-ts-mode--match-any '("$children" "$fs" "$fn"
                                                 "$preview" "$t" "$vpr" "$vpt"
                                                 "$vpd" "$vpf"))
              @font-lock-builtin-face)))
           :language openscad
           :feature builtin
           ((module_call name: (_) @font-lock-builtin-face
             (:match ,(scad-ts-mode--match-any
                       modules)
              @font-lock-builtin-face)))
           :language openscad
           :feature builtin
           ((function_call name: (_) @font-lock-builtin-face
             (:match ,(scad-ts-mode--match-any
                       functions)
              @font-lock-builtin-face)))
           :language openscad
           :feature keyword
           ((["assign" "each" "function" "let" "module"]
             @font-lock-keyword-face)
            ([(assert_statement "assert")
              (assert_expression "assert")]
             @font-lock-keyword-face)
            ((boolean) @font-lock-keyword-face)
            (["if" "else"] @font-lock-keyword-face)
            (["for" "intersection_for"]
             @font-lock-keyword-face))
           :language openscad
           :feature preprocessor
           ([(include_statement)
             (use_statement)]
            @font-lock-preprocessor-face)
           :language openscad
           :feature string
           ((string) @font-lock-string-face)
           :language openscad
           :feature constant
           (((identifier) @font-lock-constant-face
             (:equal @font-lock-constant-face "PI"))
            (undef) @font-lock-constant-face
            (arguments (assignment name: (_)
                        @font-lock-constant-face)))
           :language openscad
           :override t
           :feature escape-sequence
           ((escape_sequence) @font-lock-escape-face)
           :language openscad
           :feature literal
           ([(integer)
             (float)]
            @font-lock-number-face)
           :language openscad
           :feature bracket
           (["(" ")" "[" "]" "{" "}"] @font-lock-bracket-face)
           :language openscad
           :feature delimiter
           ([";" "," "."] @font-lock-delimiter-face)
           :language openscad
           :feature function
           ([(module_call name: (identifier)
              @font-lock-function-call-face)
             (function_call name: (identifier)
              @font-lock-function-call-face)])
           :language openscad
           :feature operator
           ((["||" "&&" "==" "!=" "<" ">" "<=" ">=" "+"
              "-" "*" "/" "%" "^" "!" ":" "="]
             @font-lock-operator-face)
            ((ternary_expression ["?" ":"]
              @font-lock-operator-face))))))

(defvar scad-ts-mode--indent-rules
  `((openscad
     ((parent-is "source_file") column-0 0)
     ((node-is ")") parent-bol 0)
     ((node-is "]") parent-bol 0)
     ((node-is "}") standalone-parent 0)
     ((node-is "else") standalone-parent 0)
     ((parent-is "block") standalone-parent scad-ts-indent-offset)
     ((parent-is "transform_chain") parent-bol scad-ts-indent-offset)
     ((match nil "arguments" nil 2 nil)
      (nth-sibling 1) 0)
     ((match nil "parameters" nil 2 nil)
      (nth-sibling 1) 0)
     ((match nil "list" nil 2 nil)
      (nth-sibling 1) 0)
     ((match nil "assignments" nil 2 nil)
      (nth-sibling 1) 0)
     ((parent-is "arguments") parent-bol scad-ts-indent-offset)
     ((parent-is "parameters")
      (nth-sibling 0) 1)
     ((parent-is "list") parent-bol scad-ts-indent-offset)
     ((parent-is "assignments") parent-bol scad-ts-indent-offset)
     ((parent-is "ERROR") parent-bol scad-ts-indent-offset)
     ((node-is "ERROR") parent-bol scad-ts-indent-offset)
     (no-node parent-bol scad-ts-indent-offset)))
  "Tree-sitter indent rules for `scad-ts-mode'.")

(defvar scad-ts-mode--font-lock-settings
  (scad-ts-mode--make-settings scad-ts-mode-modules scad-ts-mode-functions)
  "Tree-sitter font-lock settings for `scad-ts-mode'.")

(defvar scad-ts-mode--font-lock-feature-list
  '((comment definition)
    (builtin keyword preprocessor string)
    (constant escape-sequence literal)
    (bracket delimiter function operator))
  "Font-lock feature groups for syntax highlighting.")

(defvar scad-ts-mode--defun-type-regexp
  (rx bos (or "module_item" "function_item") eos)
  "Regexp describing defun-like nodes.")

(defvar scad-ts-mode--imenu-settings
  '(("Module" "\\`module_item\\'" nil nil)
    ("Function" "\\`function_item\\'" nil nil))
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

(defun scad-ts-mode--inside-comment-or-stringp (&optional pos pps)
  "Check if POS is inside a comment or string using `syntax-ppss'.

Optional argument POS is the position to check, defaulting to the current point.

Optional argument PPS is the precomputed `syntax-ppss' state, defaulting to
nil."
  (let ((pps (or pps
                 (syntax-ppss (or pos (point))))))
    (or (nth 4 pps)
        (nth 3 pps))))


(defun scad-ts-mode--resolve-path-node (node &optional dir)
  "Resolve a path NODE to an existing absolute filename with its range.

Argument NODE is a tree-sitter node whose text is a path string.

Optional argument DIR is a directory used as base for expanding NODE;
default value is nil."
  (let ((curr-path (string-trim (treesit-node-text node)
                                "\"" "\"")))
    (unless (file-name-absolute-p curr-path)
      (let ((full-name (expand-file-name curr-path dir)))
        (when (file-exists-p full-name)
          (list (treesit-node-start node)
                (treesit-node-end node)
                (prin1-to-string full-name)))))))

(defun scad-ts-mode--write-current-buffer (infile)
  "Write the current buffer to a file, resolving relative imports.

Argument INFILE is the file path where the current buffer's content will be
written."
  (save-restriction
    (widen)
    (let* ((root-node (scad-ts-mode--buffer-root-node))
           (nodes (treesit-query-capture
                   root-node
                   scad-ts--import-call-query))
           (resolved-paths
            (delq nil
                  (cl-loop
                   for (cap . node) in nodes
                   when (eq cap 'path)
                   collect
                   (scad-ts-mode--resolve-path-node node
                                                    default-directory)))))
      (if (not resolved-paths)
          (write-region (point-min)
                        (point-max) infile nil 'nomsg)
        (let ((scad-buff (current-buffer)))
          (scad-ts-mode--debug 'flymake "Resolving %d import calls in %s"
                               (length resolved-paths)
                               scad-buff)
          (with-temp-buffer
            (insert-buffer-substring scad-buff)
            (goto-char (point-max))
            (setq resolved-paths (nreverse resolved-paths))
            (pcase-dolist (`(,beg ,end ,rep) resolved-paths)
              (goto-char beg)
              (delete-region beg end)
              (insert rep))
            (write-region
             (point-min)
             (point-max) infile nil 'nomsg)))))))


(defvar-local scad-ts-mode--flymake-proc nil)


(defun scad-ts-mode-flymake (report-fn &rest _args)
  "Flymake backend, diagnostics are passed to REPORT-FN."
  (unless (executable-find
           scad-ts-mode-openscad-command)
    (error "Cannot find `%s'" scad-ts-mode-openscad-command))
  (when (process-live-p scad-ts-mode--flymake-proc)
    (delete-process scad-ts-mode--flymake-proc))
  (let* ((buffer (current-buffer))
         (infile (make-temp-file "scad-ts-mode-flymake-" nil ".scad"))
         (outfile (concat (file-name-sans-extension infile) ".ast")))
    (scad-ts-mode--write-current-buffer infile)
    (with-environment-variables
        (("OPENSCADPATH"
          (if-let* ((path (getenv "OPENSCADPATH")))
              (concat default-directory path-separator path)
            default-directory)))
      (let ((cmd-args (append (list scad-ts-mode-openscad-command "-o"
                                    outfile infile)
                              scad-ts-mode-openscad-extra-args)))
        (when scad-ts-mode-debug
          (scad-ts-mode--debug 'flymake "Running flymake command '%s' in %s"
                               (string-join (delq nil cmd-args) " ")
                               (current-buffer)))
        (setq scad-ts-mode--flymake-proc
              (make-process
               :name "scad-ts-flymake"
               :noquery t
               :connection-type 'pipe
               :buffer (generate-new-buffer " *scad-ts-flymake*")
               :command cmd-args
               :sentinel
               (lambda (proc _event)
                 (when (memq (process-status proc) '(exit signal))
                   (unwind-protect
                       (when (and (buffer-live-p buffer)
                                  (eq proc
                                      (buffer-local-value
                                       'scad-ts-mode--flymake-proc buffer)))
                         (with-current-buffer (process-buffer proc)
                           (goto-char (point-min))
                           (let (diags)
                             (while (search-forward-regexp
                                     "^\\(ERROR\\|WARNING\\): \\(.*?\\),? in file [^,]+, line \\([0-9]+\\)"
                                     nil t)
                               (let ((msg (match-string 2))
                                     (type (if (equal (match-string 1)
                                                      "ERROR")
                                               :error :warning))
                                     (region (flymake-diag-region
                                              buffer
                                              (string-to-number
                                               (match-string 3)))))
                                 (push (flymake-make-diagnostic buffer
                                                                (car region)
                                                                (cdr region)
                                                                type
                                                                msg)
                                       diags)))
                             (funcall report-fn (nreverse diags)))))
                     (delete-file outfile)
                     (delete-file infile)
                     (kill-buffer (process-buffer proc)))))))))))

(defun scad-ts-mode-enable-flymake ()
  "Enable Flymake diagnostics by adding the SCAD backend function locally."
  (interactive)
  (when buffer-file-name
    (add-hook 'flymake-diagnostic-functions #'scad-ts-mode-flymake nil 'local)
    (unless (bound-and-true-p flymake-mode)
      (flymake-mode 1))))

(defun scad-ts-mode-disable-flymake ()
  "Remove the local Flymake diagnostic function hook for this mode."
  (interactive)
  (remove-hook 'flymake-diagnostic-functions #'scad-ts-mode-flymake 'local))

;;;###autoload
(define-derived-mode scad-ts-mode prog-mode "OpenSCAD"
  "Major mode for editing OpenSCAD using tree-sitter."
  :group 'scad-ts
  :after-hook (c-update-modeline)
  :syntax-table scad-ts-mode-syntax-table
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
  (setq-local treesit-simple-indent-rules scad-ts-mode--indent-rules)
  (setq-local electric-indent-chars
              (append "{}();" electric-indent-chars))
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

(defun scad-ts-mode--font-lock-updater (symbol newval operation &rest _)
  "Update font-lock settings when modules or functions lists are set.

Argument SYMBOL is the variable symbol being updated.

Argument NEWVAL is the new value assigned to SYMBOL.

Argument OPERATION is the update operation SYMBOL, expected to be `set'.

Remaining arguments _ are ignored."
  (when (eq operation 'set)
    (let* ((args
            (pcase symbol
              ('scad-ts-mode-modules
               (list newval scad-ts-mode-functions))
              ('scad-ts-mode-functions
               (list scad-ts-mode-modules newval)))))
      (cond ((and (not (memq symbol '(scad-ts-mode-modules
                                      scad-ts-mode-functions)))
                  (not args))
             (display-warning 'scad-ts
                              (format
                               "Unexpected symbol `%s' was set in watcher for `scad-ts-mode--font-lock-updater'"
                               symbol)))
            ((not args)
             (display-warning 'scad-ts
                              (format
                               "Ignoring null value for `%s'"
                               symbol)))
            (t (setq scad-ts-mode--font-lock-settings
                     (apply 'scad-ts-mode--make-settings args)))))))

(add-variable-watcher 'scad-ts-mode-modules 'scad-ts-mode--font-lock-updater)

(add-variable-watcher 'scad-ts-mode-functions 'scad-ts-mode--font-lock-updater)

(provide 'scad-ts-mode)
;;; scad-ts-mode.el ends here
