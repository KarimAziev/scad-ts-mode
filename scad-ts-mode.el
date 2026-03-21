;;; scad-ts-mode.el --- Tree-sitter major mode for OpenSCAD -*- lexical-binding: t; -*-

;; Copyright (C) Karim Aziiev <karim.aziiev@gmail.com>

;; Author: Karim Aziiev <karim.aziiev@gmail.com>
;; URL: https://github.com/KarimAziev/scad-ts-mode
;; Version: 0.1.0
;; Keywords: languages
;; Package-Requires: ((emacs "30.1"))
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
(require 'transient)


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
  "Number of spaces for each indentation step in `scad-ts-mode'."
  :type 'natnum
  :safe 'natnump
  :group 'scad-ts)


(defcustom scad-ts-mode-openscad-command "openscad"
  "OpenSCAD executable name or path used for rendering, flymake, and help.

Name of the OpenSCAD executable used for rendering previews, running
Flymake checks, and querying command-line help.

The value should be a string accepted by `executable-find', such as an
absolute file name or a program name found in variable `exec-path'."
  :group 'scad-ts
  :type 'string)

(defcustom scad-ts-mode-openscad-extra-args nil
  "Extra command-line arguments appended to the OpenSCAD flymake command.

Extra command line arguments passed to the OpenSCAD executable.

The value is a list of strings, each string being one argument.

Example value: \\='(\"--backend=Manifold\" \"--enable=roof\" \"--enable=textmetrics\")"
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
           (const :tag "Preview" preview)
           (symbol :tag "Other"))))

(defcustom scad-ts-preview-projection 'perspective
  "Projection mode used for OpenSCAD preview rendering.

The value is a symbol, either `perspective' or `ortho'.

When set to `perspective', the preview uses perspective projection.

When set to `ortho', the preview uses orthographic projection.

The projection can be toggled from a preview buffer with the command
`scad-ts-preview-projection'."
  :type '(radio (const ortho)
                (const perspective)))

(defcustom scad-ts-preview-camera '(0 0 0 50 0 20 500)
  "Camera translation, rotation, and distance as 7 integers for preview.

A list of seven integers describing the OpenSCAD preview camera.

The elements are (tx ty tz rx ry rz dist), where tx..tz are translation
offsets, rx..rz are rotation angles in degrees, and dist is the camera
distance.

The value is passed to OpenSCAD as a comma-separated --camera argument.

Changing any element affects the next preview render, and the current
state is shown in the preview mode line as \"[tx ty tz] [rx ry rz] dist\"."
  :type '(repeat integer))

(defcustom scad-ts-mode-preview-refresh 1.0
  "Delay in seconds before rerendering the preview after buffer changes.

Delay in seconds before re-rendering the preview after buffer edits.

A number schedules a one-shot timer after each change; further edits
restart the timer so rendering happens after the last change.

A value of nil disables automatic refresh on edits; rendering must be
triggered manually."
  :type '(choice (const nil) number))

(defcustom scad-ts-preview-colorscheme '("Tomorrow" . "Tomorrow Night")
  "Color scheme name, or (LIGHT . DARK) pair chosen by background.

Color scheme used for OpenSCAD preview rendering.

The value can be a string naming a single scheme, or a cons cell
\\=(LIGHT . DARK) selecting between two schemes based on whether the
current theme background is light or dark.

When set to a cons cell, the car is used for light backgrounds and
the cdr is used for dark backgrounds.

A buffer-local value may be set to override the global value for a
single preview buffer."
  :type '(choice string (cons string string)))

(defcustom scad-ts-preview-view '("axes" "scales")
  "List of views to be rendered.
Options are axes, crosshairs, edges, scales, wireframe."
  :type '(repeat string))

(defcustom scad-ts-mode-autopopup-preview nil
  "Whether to automatically show the preview popup.

Non-nil means automatically display the preview buffer after rendering.

Nil means keep the preview buffer hidden unless displayed manually."
  :group 'scad-ts
  :type 'boolean)

(defcustom scad-ts-preview-translation-step 10
  "Default step size for translating the camera in screen-aligned directions.

It is used as the fallback value in functions that translate
the camera in various directions such as left, right, up, down,
forward, and backward."
  :group 'scad-ts
  :type 'integer)

(defcustom scad-ts-mode-preview-hide-regexp
  (rx bol
      (or
       (seq "FALLBACK" (+ space)
            "(log once):")
       (seq
        "Normalized CSG tree has"
        (+ space)
        (+ digit)
        (+ space) "elements")
       (seq "Geometries in cache:")
       (seq
        "CGAL Polyhedrons in cache")
       (seq
        "CGAL cache size in bytes")
       (seq
        "Geometry cache size in bytes"))
      (* not-newline) eol)
  "Regular expression matching preview log lines to hide from displayed output.

Regular expression matching preview output lines to remove.

When a line between the preview buffer bounds matches the expression,
the entire line is deleted.

Intended for filtering noisy status messages such as cache summaries
or CSG normalization reports."
  :type 'regexp)


(defcustom scad-ts-mode-saveable-variables '(scad-ts-preview-projection
                                             scad-ts-preview-camera
                                             scad-ts-preview-view
                                             scad-ts-mode-openscad-extra-args)
  "List of OpenSCAD related variables eligible for saving.

This includes variables that can be saved using the command
`scad-ts-save-variables'."
  :type '(set :greedy t
          (const scad-ts-preview-view)
          (const scad-ts-preview-projection)
          (const scad-ts-preview-camera)
          (repeat :inline t
           (symbol))))


(defcustom scad-ts-preview-allow-reverse t
  "Allow cycling of view commands.

This setting applies to the following pairs of commands:
- `scad-ts-preview-top-view'  <->  `scad-ts-preview-bottom-view'
- `scad-ts-preview-left-view' <->  `scad-ts-preview-right-view'
- `scad-ts-preview-front-view' <->  `scad-ts-preview-back-view'

For example, if you call `scad-ts-preview-top-view' while the coordinates
already represent a top view,the function will invoke its reverse command
\(`scad-ts-preview-bottom-view') and vice versa."
  :group 'scad-ts
  :type 'boolean)

(defface scad-ts-preview-warning
  '((t :inherit warning))
  "Face for WARNING lines.")

(defface scad-ts-preview-error
  '((t :inherit error))
  "Face for ERROR lines.")

(defface scad-ts-preview-echo
  '((t :inherit success))
  "Face for ECHO lines.")

(defconst scad-ts-mode-include-query
  '((include_statement (include_path) @path)))

(defconst scad-ts-mode-use-query
  '((use_statement (include_path) @path)))

(defconst scad-ts-mode-include-and-use-query
  (append scad-ts-mode-include-query
          scad-ts-mode-use-query))

(defconst scad-ts-preview-font-lock-keywords
  '(("^WARNING:.*" . 'scad-ts-preview-warning)
    ("^ERROR:.*"   . 'scad-ts-preview-error)
    ("^ECHO:.*"    . 'scad-ts-preview-echo)))


(defvar-local scad-ts-mode--preview-render-auto-display-disabled
  (not scad-ts-mode-autopopup-preview))

(defvar-local scad-ts-mode--preview-force-display
  nil)

(defvar-local scad-ts--preview-buffer nil)

(defvar scad-ts-preview--openscad-help-cache nil
  "Cache for parsed OpenSCAD help options.")


(defun scad-ts--preview-colorscheme ()
  "Color scheme depending on Emacs theme."
  (cond ((stringp scad-ts-preview-colorscheme)
         scad-ts-preview-colorscheme)
        ((color-dark-p (color-name-to-rgb (face-background 'default)))
         (cdr scad-ts-preview-colorscheme))
        (t (car scad-ts-preview-colorscheme))))

(defvar-local scad-ts-mode--preview-proc nil)
(defvar-local scad-ts-mode--preview-timer nil)
(defvar-local scad-ts-mode--preview-image nil)

(defvar-local scad-ts-mode--preview-mode-status nil)
(defvar-local scad-ts-mode--preview-mode-camera nil)

(defun scad-ts-preview-projection ()
  "Toggle the preview projection between orthographic and perspective."
  (interactive nil scad-ts-preview-mode)
  (setq-local scad-ts-preview-projection
              (if (eq scad-ts-preview-projection 'ortho)
                  'perspective
                'ortho))
  (scad-ts-mode--preview-render))


(defun scad-ts-mode--preview-delete ()
  "Delete the preview image file and clear its stored path."
  (when scad-ts-mode--preview-image
    (delete-file scad-ts-mode--preview-image)
    (setq scad-ts-mode--preview-image nil)))

(defun scad-ts-mode--preview-status (status)
  "Update mode line of preview buffer with STATUS."
  (setq scad-ts-mode--preview-mode-camera
        (apply #'format "[%d %d %d] [%d %d %d] %d"
               scad-ts-preview-camera)
        scad-ts-mode--preview-mode-status status)
  (force-mode-line-update))

(defun scad-ts-mode--preview-kill ()
  "Stop and clear the preview process and timer if they are running."
  (when (process-live-p scad-ts-mode--preview-proc)
    (delete-process scad-ts-mode--preview-proc)
    (setq scad-ts-mode--preview-proc nil))
  (when scad-ts-mode--preview-timer
    (cancel-timer scad-ts-mode--preview-timer)
    (setq scad-ts-mode--preview-timer nil)))

(defvar scad-ts-mode--preview-output-buffer-name
  "*scad-ts preview output*")

(defun scad-ts--preview-ensure-output-buffer ()
  "Make sure the output buffer has highlighting configured."
  (with-current-buffer (get-buffer-create
                        scad-ts-mode--preview-output-buffer-name)
    (setq-local window-point-insertion-type t)
    (setq buffer-read-only t)
    (setq-local font-lock-defaults '(scad-ts-preview-font-lock-keywords t))
    (setq-local font-lock-multiline t)
    (font-lock-mode 1)))

(defun scad-ts-mode--preview-delete-hidden-lines (beg end)
  "Delete lines matching `scad-ts-mode-preview-hide-regexp` between BEG and END."
  (save-excursion
    (goto-char beg)
    (let ((limit (copy-marker end)))
      (while (re-search-forward scad-ts-mode-preview-hide-regexp limit t)
        (delete-region (line-beginning-position)
                       (min (point-max)
                            (1+ (line-end-position))))))))

(defun scad-ts-mode--preview-scroll-output-window ()
  "If the output buffer is visible, keep its window scrolled to the bottom."
  (when-let* ((win (get-buffer-window
                    scad-ts-mode--preview-output-buffer-name 0)))
    (with-selected-window win
      (goto-char (point-max))
      (set-window-point win (point-max)))))

(defun scad-ts-mode--preview-output-filter (proc chunk)
  "Process filter for OpenSCAD output: insert, hide noise, highlight, scroll.

Argument PROC is a process whose buffer receives output text.

Argument CHUNK is a string of process output to insert at the process
mark."
  (scad-ts--preview-ensure-output-buffer)
  (when (buffer-live-p (process-buffer proc))
    (with-current-buffer (process-buffer proc)
      (let ((inhibit-read-only t)
            (beg (marker-position (process-mark proc))))
        (save-excursion
          (goto-char beg)
          (insert chunk)
          (set-marker (process-mark proc)
                      (point))
          (scad-ts-mode--preview-delete-hidden-lines beg (point))
          (font-lock-flush beg (point)))
        (goto-char (point-max))))
    (scad-ts-mode--preview-scroll-output-window)))

(defun scad-ts-mode--preview-render (&optional _)
  "Render the preview buffer via OpenSCAD and display the resulting PNG."
  (if (not (buffer-live-p scad-ts--preview-buffer))
      (scad-ts-mode--preview-status "Dead")
    (let* ((buffer (current-buffer))
           (win (get-buffer-window buffer)))
      (scad-ts-mode--preview-kill)
      (scad-ts-mode--preview-status "Render")
      (unless (and scad-ts-mode--preview-render-auto-display-disabled
                   (not scad-ts-mode--preview-force-display))
        (setq scad-ts-mode--preview-force-display nil)
        (unless win
          (setq win (display-buffer
                     buffer '(nil (inhibit-same-window . t))))))
      (let* ((infile (make-temp-file "scad-ts-preview-" nil ".scad"))
             (basefile (file-name-sans-extension infile))
             (outfile (concat basefile ".tmp.png"))
             (win-size (if (and win
                                (window-live-p win))
                           (cons (window-pixel-width win)
                                 (window-pixel-height win))
                         (cons 756 934))))
        (with-current-buffer scad-ts--preview-buffer
          (scad-ts-mode--write-current-buffer infile))
        (with-environment-variables
            ;; Setting the OPENSCADPATH to the current directory allows openscad to pick
            ;; up other local files with `include <file.scad>'.
            (("OPENSCADPATH"
              (if-let* ((path (getenv "OPENSCADPATH")))
                  (concat default-directory path-separator path)
                default-directory)))
          (setq scad-ts-mode--preview-proc
                (make-process
                 :noquery t
                 :connection-type 'pipe
                 :name "scad-ts-preview"
                 :buffer scad-ts-mode--preview-output-buffer-name
                 :filter #'scad-ts-mode--preview-output-filter
                 :sentinel
                 (lambda (proc _event)
                   (unwind-protect
                       (when (and (buffer-live-p buffer)
                                  (memq (process-status proc) '(exit signal)))
                         (with-current-buffer buffer
                           (setq scad-ts-mode--preview-proc nil)
                           (if (not (ignore-errors
                                      (and (file-exists-p outfile)
                                           (> (file-attribute-size
                                               (file-attributes outfile))
                                              0))))
                               (scad-ts-mode--preview-status "Error")
                             (with-silent-modifications
                               (scad-ts-mode--preview-delete)
                               (setq scad-ts-mode--preview-image
                                     (concat basefile ".png"))
                               (rename-file outfile scad-ts-mode--preview-image)
                               (erase-buffer)
                               (insert
                                (propertize
                                 "#" 'display
                                 `(image :type png
                                         :file ,scad-ts-mode--preview-image))))
                             (scad-ts-mode--preview-status "Done"))))
                     (delete-file infile)
                     (delete-file outfile)))
                 :command
                 (let ((cmd (append
                             (list scad-ts-mode-openscad-command
                                   "-o" outfile
                                   "--preview"
                                   (format "--projection=%s"
                                           scad-ts-preview-projection)
                                   (format "--imgsize=%d,%d"
                                           (car win-size)
                                           (cdr win-size))
                                   (format "--view=%s"
                                           (mapconcat
                                            #'identity
                                            scad-ts-preview-view ","))
                                   (format "--camera=%s"
                                           (mapconcat
                                            #'number-to-string
                                            scad-ts-preview-camera ","))
                                   (format "--colorscheme=%s"
                                           (scad-ts--preview-colorscheme))
                                   infile)
                             scad-ts-mode-openscad-extra-args)))
                   (when scad-ts-mode-debug
                     (scad-ts-mode--debug 'preview "Running %s"
                                          (string-join
                                           (delq nil cmd) " ")))
                   cmd))))))))


(defun scad-ts-mode--preview-reset (&rest _)
  "Reset camera settings and render."
  (setq-local scad-ts-preview-camera
              (copy-sequence (default-value 'scad-ts-preview-camera))
              scad-ts-preview-projection
              (default-value 'scad-ts-preview-projection))
  (scad-ts-mode--preview-render))

(defun scad-ts-mode--preview-change (&rest _)
  "Schedule a delayed preview rerender after changes, marking it stale."
  (if (not (buffer-live-p scad-ts--preview-buffer))
      (remove-hook 'after-change-functions
                   #'scad-ts-mode--preview-change 'local)
    (let ((buffer scad-ts--preview-buffer))
      (with-current-buffer buffer
        (scad-ts-mode--preview-kill)
        (scad-ts-mode--preview-status "Stale")
        (setq scad-ts-mode--preview-timer
              (run-with-timer
               scad-ts-mode-preview-refresh nil
               (lambda ()
                 (when (buffer-live-p buffer)
                   (with-current-buffer buffer
                     (setq scad-ts-mode--preview-timer nil)
                     (scad-ts-mode--preview-render))))))))))

(defmacro scad-ts-mode--define-preview-move (name idx off)
  "Define a command to move a camera coordinate by OFFSET and re-render.

Argument NAME is a symbol used to form the preview move function name.

Argument IDX is a number used as the index into `scad-ts-preview-camera'.

Argument OFF is a number used as the signed base movement amount."
  `(defun ,(intern (format "scad-ts-preview-%s" name))
       (&optional offset)
     "Move camera by OFFSET."
     (interactive "P" scad-ts-preview-mode)
     (cl-incf (nth ,idx scad-ts-preview-camera)
              (* (cl-signum ,off)
                 (if offset (prefix-numeric-value offset) ,(abs off))))
     (scad-ts-mode--preview-render)))

(scad-ts-mode--define-preview-move rotate-x+ 3 10)
(scad-ts-mode--define-preview-move rotate-x- 3 -10)
(scad-ts-mode--define-preview-move rotate-y+ 4 10)
(scad-ts-mode--define-preview-move rotate-y- 4 -10)
(scad-ts-mode--define-preview-move rotate-z+ 5 10)
(scad-ts-mode--define-preview-move rotate-z- 5 -10)
(scad-ts-mode--define-preview-move distance- 6 100)
(scad-ts-mode--define-preview-move distance+ 6 -100)

(defvar-keymap scad-ts-preview-mode-map
  :doc "Keymap for SCAD preview buffers."
  "p" #'scad-ts-preview-projection
  "-" #'scad-ts-preview-distance-
  "+" #'scad-ts-preview-distance+
  "<right>" #'scad-ts-preview-rotate-z-
  "<left>" #'scad-ts-preview-rotate-z+
  "<up>" #'scad-ts-preview-rotate-x+
  "<down>" #'scad-ts-preview-rotate-x-
  "?" #'scad-ts-preview-menu
  "f" #'scad-ts-preview-front-view
  "t" #'scad-ts-preview-top-view
  "l" #'scad-ts-preview-left-view
  "r" #'scad-ts-preview-right-view
  "b" #'scad-ts-preview-back-view
  "d" #'scad-ts-preview-bottom-view
  "M-<left>" #'scad-ts-preview-translate-left
  "M-<right>" #'scad-ts-preview-translate-right
  "M-<up>" #'scad-ts-preview-translate-up
  "M-<down>" #'scad-ts-preview-translate-down
  "C-h C-e" #'scad-ts-show-output-logs)

(define-derived-mode scad-ts-preview-mode special-mode "SCAD-TS/Preview"
  "Render and display an OpenSCAD PNG preview, updating on window size changes.

Display an OpenSCAD render preview as a read-only image buffer.

Show camera settings and render status in the mode line, reset camera and
projection on revert, re-render automatically when the window size changes, and
clean up any running render process, timers, and temporary image files when the
buffer is killed."
  :interactive nil
  :abbrev-table nil
  :syntax-table nil
  (setq-local buffer-read-only t
              line-spacing nil
              cursor-type nil
              cursor-in-non-selected-windows nil
              left-fringe-width 1
              right-fringe-width 1
              left-margin-width 0
              right-margin-width 0
              truncate-lines nil
              show-trailing-whitespace nil
              display-line-numbers nil
              fringe-indicator-alist '((truncation . nil))
              revert-buffer-function #'scad-ts-mode--preview-reset
              mode-line-position '(" " scad-ts-mode--preview-mode-camera)
              mode-line-process '(" " scad-ts-mode--preview-mode-status)
              mode-line-modified nil
              mode-line-mule-info nil
              mode-line-remote nil)
  (add-hook 'kill-buffer-hook #'scad-ts-mode--preview-kill nil 'local)
  (add-hook 'kill-buffer-hook #'scad-ts-mode--preview-delete nil 'local)
  (add-hook 'window-size-change-functions
            ;; On Emacs 31 `window-size-change-functions' run in current buffer
            (static-if (>= emacs-major-version 31)
                #'scad-ts-mode--preview-render
              (let ((buf (current-buffer)))
                (lambda (_)
                  (with-current-buffer buf
                    (scad-ts-mode--preview-render)))))
            nil 'local))



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
              (list (assq type scad-ts-mode-include-and-use-query))
            scad-ts-mode-include-and-use-query))))
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
        (let ((buff (current-buffer)))
          (scad-ts-mode--debug 'flymake "Resolving %d import calls in %s"
                               (length resolved-paths)
                               buff)
          (with-temp-buffer
            (insert-buffer-substring buff)
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


(defun scad-ts-mode--capture-path-query (&optional query transformer)
  "Collect captured `path' nodes from a QUERY, optionally transforming them.

Optional argument QUERY is a treesit query passed to
`treesit-query-capture'; default value nil.

Optional argument TRANSFORMER is a function applied to each captured
path node; default value nil."
  (let* ((root-node (scad-ts-mode--buffer-root-node))
         (nodes (treesit-query-capture
                 root-node
                 query)))
    (let ((node nil)
          (cap nil)
          (items))
      (while (consp nodes)
        (progn
          (setq node
                (car nodes))
          (setq cap
                (car-safe
                 (prog1 node
                   (setq node
                         (cdr node))))))
        (when (eq cap 'path)
          (if transformer
              (when-let* ((result (if transformer
                                      (funcall transformer node)
                                    node)))
                (push result items))
            (push node items)))
        (setq nodes
              (cdr nodes)))
      (nreverse items))))


(defun scad-ts-mode--scan-current-buffer-deps ()
  "Return a list of expanded filenames that current buffer includes/uses."
  (scad-ts-mode--capture-path-query
   scad-ts-mode-include-and-use-query
   (lambda (node)
     (let* ((txt (string-trim (treesit-node-text node t) "<" ">"))
            (file (if (file-name-absolute-p txt)
                      txt
                    (expand-file-name txt))))
       (when (and (file-exists-p file)
                  (not (file-directory-p file)))
         file)))))

(defun scad-ts-mode--scan-file-deps (file)
  "Return a list of expanded filenames that FILE includes/uses.
FILE is read from disk; buffer contents (if any) are not used."
  (with-temp-buffer
    (insert-file-contents file)
    (let ((default-directory (file-name-directory (or file default-directory))))
      (scad-ts-mode--scan-current-buffer-deps))))


(defun scad-ts-mode--check-file-dep-p (file)
  "Return non-nil if FILE is (recursively) imported from current buffer.

Searches the current buffer for include/use directives and then walks the
dependency graph. Each file is parsed at most once."
  (let* ((target (expand-file-name file))
         (visited (make-hash-table :test 'equal))
         (queue nil)
         found)
    (dolist (dep (scad-ts-mode--scan-current-buffer-deps))
      (unless (gethash dep visited)
        (puthash dep t visited)
        (push dep queue)))
    ;; BFS
    (while (and queue (not found))
      (let ((cur (pop queue)))
        (when (string= cur target)
          (setq found t))
        (unless found
          (let ((deps
                 (if-let* ((buf (get-file-buffer cur)))
                     (with-current-buffer buf
                       (scad-ts-mode--scan-current-buffer-deps))
                   (scad-ts-mode--scan-file-deps cur))))
            (dolist (d deps)
              (unless (gethash d visited)
                (puthash d t visited)
                (when (string= d target)
                  (setq found t))
                (push d queue)))))))
    found))

(defun scad-ts--reload-related-preview-buffer ()
  "Reload the preview buffer if the current file is imported."
  (let ((wnd)
        (wnd-lst (window-list))
        (curr-buff (current-buffer))
        (curr-wind (selected-window))
        (file buffer-file-name))
    (while (and file (setq wnd (pop wnd-lst)))
      (unless (eq wnd curr-wind)
        (let* ((wnd-buff (window-buffer wnd))
               (mode (buffer-local-value 'major-mode wnd-buff))
               (orig-buff (and (eq mode 'scad-ts-preview-mode)
                               (buffer-local-value 'scad-ts--preview-buffer
                                                   wnd-buff))))
          (when (and orig-buff
                     (buffer-live-p orig-buff)
                     (not (eq orig-buff curr-buff))
                     (with-current-buffer orig-buff
                       (let ((imported (scad-ts-mode--check-file-dep-p file)))
                         (message "Checking file %s in buffer %s %s " file
                                  orig-buff imported))))
            (when (buffer-live-p wnd-buff)
              (with-current-buffer wnd-buff
                (message "Scad-ts: Refreshing %s" wnd-buff)
                (scad-ts-mode--preview-render)))))))))

(defun scad-ts-mode-preview ()
  "Preview OpenSCAD models in real-time within Emacs."
  (interactive nil scad-ts-mode)
  (cond ((or
          (not scad-ts-mode--preview-render-auto-display-disabled)
          (not (buffer-live-p scad-ts--preview-buffer)))
         (setq scad-ts--preview-buffer
               (with-current-buffer
                   (get-buffer-create
                    (format "*scad-ts preview: %s*" (buffer-name)))
                 (scad-ts-preview-mode)
                 (setq scad-ts-mode--preview-force-display t)
                 (current-buffer)))
         (when scad-ts-mode-preview-refresh
           (add-hook 'after-change-functions #'scad-ts-mode--preview-change nil
                     'local))
         (let ((orig-buffer (current-buffer)))
           (with-current-buffer scad-ts--preview-buffer
             (setq scad-ts--preview-buffer orig-buffer)
             (scad-ts-mode--preview-reset))))
        ((not (get-buffer-window scad-ts--preview-buffer))
         (display-buffer
          scad-ts--preview-buffer
          '(nil (inhibit-same-window . t))))
        (t
         (let ((orig-buffer (current-buffer)))
           (with-current-buffer scad-ts--preview-buffer
             (setq scad-ts--preview-buffer orig-buffer)
             (scad-ts-mode--preview-reset))))))

(defun scad-ts-mode--watch-preview-command ()
  "Re-enable auto preview display when the preview command is invoked."
  (when (eq this-command 'scad-ts-mode-preview)
    (remove-hook 'pre-command-hook #'scad-ts-mode--watch-preview-command t)
    (when scad-ts-mode--preview-render-auto-display-disabled
      (scad-ts-mode-toggle-auto-preview-display))))

(defun scad-ts-mode-toggle-auto-preview-display ()
  "Toggle automatic preview display and sync the setting with the preview buffer."
  (interactive)
  (setq scad-ts-mode--preview-render-auto-display-disabled
        (not scad-ts-mode--preview-render-auto-display-disabled))
  (if scad-ts-mode--preview-render-auto-display-disabled
      (add-hook 'pre-command-hook #'scad-ts-mode--watch-preview-command nil t)
    (remove-hook 'pre-command-hook #'scad-ts-mode--watch-preview-command t))
  (cond ((not (buffer-live-p scad-ts--preview-buffer))
         nil)
        (scad-ts-mode--preview-render-auto-display-disabled
         (with-current-buffer scad-ts--preview-buffer
           (setq scad-ts-mode--preview-render-auto-display-disabled t)))
        (t
         (with-current-buffer scad-ts--preview-buffer
           (setq scad-ts-mode--preview-render-auto-display-disabled nil)))))

(defun scad-ts--format-menu-heading (title &optional note)
  "Format TITLE as a menu heading.
When NOTE is non-nil, append it the next line."
  (let ((no-wb (= (frame-bottom-divider-width) 0)))
    (format "%s%s%s"
            (propertize title 'face `(:inherit transient-heading
                                      :overline ,no-wb)
                        'display '((height 1.1)))
            (propertize " " 'face `(:inherit transient-heading
                                    :overline ,no-wb)
                        'display '(space :align-to right))
            (propertize (if note (concat "\n" note) "") 'face
                        'font-lock-doc-face))))

(defun scad-ts--format-toggle (description value &optional on-label off-label
                                           left-separator right-separator
                                           divider align)
  "Format a toggle switch with DESCRIPTION and alignment options.

Argument DESCRIPTION is a string that provides a description for the toggle.

Argument VALUE is a boolean that determines the toggle state.

Optional argument ON-LABEL is a string label for the \"on\" state, defaulting to
\"+\".

Optional argument OFF-LABEL is a string label for the \"off\" state, defaulting
to \"-\".

Optional argument LEFT-SEPARATOR is a string used as the left separator,
defaulting to \"[\".

Optional argument RIGHT-SEPARATOR is a string used as the right separator,
defaulting to \"]\".

Optional argument DIVIDER is a character used to fill space, defaulting to
\".\".

Optional argument ALIGN is an integer specifying the alignment width, defaulting
to 20."
  (let* ((description (or description ""))
         (align (apply #'max (list (+ 5 (length description))
                                   (or align 20))))
         (face (if value 'success 'transient-inactive-value)))
    (concat
     (substring (concat
                 (or description "")
                 " "
                 (make-string (1- (1- align))
                              (if (stringp divider)
                                  (string-to-char divider)
                                (or divider ?\.)))
                 " ")
                0
                align)
     (or left-separator "[")
     (if value
         (propertize
          (or on-label "+")
          'face
          face)
       (propertize
        (or off-label "-")
        'face
        face))
     (or right-separator "]")
     " ")))

(defun scad-ts-preview-change-theme (next-val)
  "Change the SCAD preview theme to the selected NEXT-VAL.

Argument NEXT-VAL is the name of the theme to be applied."
  (interactive
   (list
    (completing-read "Theme: "
                     (remove
                      (scad-ts--preview-colorscheme)
                      (car
                       (last
                        (assoc-string
                         "--colorscheme"
                         scad-ts-preview--openscad-help-cache)))))))
  (cond ((derived-mode-p
          'scad-ts-preview-mode)
         (setq-local scad-ts-preview-colorscheme next-val)
         (scad-ts-mode--preview-render))
        (t
         (setq scad-ts-preview-colorscheme next-val))))



(defun scad-ts--openscad-help ()
  "Cache and return parsed OpenSCAD help options."
  (or scad-ts-preview--openscad-help-cache
      (setq scad-ts-preview--openscad-help-cache
            (with-temp-buffer
              (call-process scad-ts-mode-openscad-command nil t nil "--help")
              (goto-char (point-min))
              (scad-ts-preview--parse-openscad-help)))))

(defun scad-ts-preview--parse-openscad-help ()
  "Parse OpenSCAD help text and return a list of options with details."
  (let ((re
         "^ *\\(\\(-[a-zZ-A]\\)\\([ ]\\[[\s]\\(--[a-z-_]+\\) \\]\\)?\\|\\(--[a-z-_]+\\)\\)\\([\s]\\(arg\\)\\)?")
        (shortarg-num 2)
        (long-arg-num '(4 5))
        (arg-num 7)
        (results))
    (while (re-search-forward re nil t)
      (let* ((short (match-string-no-properties shortarg-num))
             (long (or (match-string-no-properties (car long-arg-num))
                       (match-string-no-properties (cadr long-arg-num))))
             (has-arg (match-string-no-properties arg-num))
             (description
              (progn
                (skip-chars-forward " \t")
                (let ((start (point)))
                  (while (and (not (eobp))
                              (not (looking-at-p "^ *-")))
                    (forward-line 1))
                  (string-trim
                   (buffer-substring-no-properties
                    start
                    (point))))))
             (choices
              (when-let* ((start (string-match-p
                                  "\\(\\([a-zZ-A-_]+\\)[\s\t\n]*|\\)+"
                                  description))
                          (choices
                           (mapcar
                            #'string-trim
                            (split-string
                             (substring-no-properties description
                                                      start)
                             "|"
                             t))))
                choices)))
        (push (list long short has-arg choices) results)))
    (nreverse results)))

(defun scad-ts-mode--standard-custom-value (sym)
  "Return the standard value of the symbol SYM."
  (eval (car (get sym 'standard-value))))

(defun scad-ts-mode--saved-custom-value (sym)
  "Return the saved value of the symbol SYM."
  (eval (car (get sym 'saved-value))))

(defun scad-ts-mode--custom-variable-changed-p (sym)
  "Return non nil if variable SYM is saveable and differs from the default."
  (when (custom-variable-p sym)
    (let ((val (symbol-value sym))
          (has-saved-val (get sym 'saved-value))
          (has-standard-val (get sym 'standard-value)))
      (when (or has-saved-val has-standard-val)
        (let ((custom-val (funcall (if has-saved-val
                                       #'scad-ts-mode--saved-custom-value
                                     #'scad-ts-mode--standard-custom-value)
                                   sym)))
          (not (equal val
                      custom-val)))))))

(defvar scad-ts--view-suffixes nil)
(defvar scad-ts--enable-suffixes nil)

(defun scad-ts-mode--set-variable (var value &optional save comment)
  "Set or SAVE a variable VAR to VALUE, optionally with COMMENT.

Argument VAR is the variable to set.

Argument VALUE is the new value for the variable VAR.

Optional argument SAVE is a boolean; if non-nil, the variable is saved to the
user's custom file.

Optional argument COMMENT is a string used as a comment when saving the
variable. It defaults to \"Saved by scad-ts-mode.\"."
  (let ((customp (custom-variable-p var)))
    (if (and save customp)
        (customize-save-variable var value
                                 (or comment "Saved by scad-ts-mode."))
      (if customp
          (funcall (or (get var 'custom-set) 'set-default) var value)
        (set-default var value)))))

(defvar scad-ts--display-options-suffixes
  (append
   (list '("p"
           (lambda ()
             (interactive)
             (let ((next-val
                    (if
                        (eq
                         scad-ts-preview-projection
                         'ortho)
                        'perspective
                      'ortho)))
              (cond ((derived-mode-p
                      'scad-ts-preview-mode)
                     (setq-local scad-ts-preview-projection next-val)
                     (scad-ts-mode--preview-render))
               (t
                (setq scad-ts-preview-projection next-val)))
              (transient-setup
               transient-current-command)))
           :description
           (lambda ()
             (concat "("
              (propertize "["
               'face
               'transient-inactive-value)
              (mapconcat (lambda (sym)
                           (let ((face
                                  (if
                                      (eq
                                       scad-ts-preview-projection
                                       sym)
                                      'transient-value
                                    'transient-inactive-value)))
                            (propertize
                             (capitalize
                              (format
                               "%s"
                               sym))
                             'face
                             face)))
               (list 'perspective 'ortho)
               (propertize "|" 'face
                'transient-inactive-value))
              (propertize "]" 'face
               'transient-inactive-value)
              ")")))
         '("R" "Reset"
           (lambda ()
             (interactive)
             (scad-ts-mode--preview-reset))
           :inapt-if (lambda ()
                       (and
                        (equal scad-ts-preview-camera
                         (copy-sequence (default-value
                                         'scad-ts-preview-camera)))
                        (equal scad-ts-preview-projection
                         (default-value 'scad-ts-preview-projection)))))
         '("T" scad-ts-preview-change-theme
           :description (lambda ()
                          (concat "Change Theme ("
                           (propertize
                            (format
                             "%s"
                             (scad-ts--preview-colorscheme))
                            'face
                            'transient-value)
                           ")"))))))


(defun scad-ts--get-modified-variables ()
  "Return modified variables from `scad-ts-mode-saveable-variables'."

  (seq-filter #'scad-ts-mode--custom-variable-changed-p
              scad-ts-mode-saveable-variables))

(defun scad-ts-save-variables ()
  "Save value of modified variables from `scad-ts-mode-saveable-variables'."
  (interactive)
  (dolist (var (scad-ts--get-modified-variables))
    (scad-ts-mode--set-variable var (symbol-value var)
                                t)))

(defvar scad-ts--saveable-options
  (append (mapcar
           (pcase-lambda (`(,key ,doc ,var))
             (list key
                   (lambda ()
                     (interactive)
                     (scad-ts-mode--set-variable var
                                                 (symbol-value var) t
                                                 "Saved by scad-ts-mode.")
                     (transient-setup transient-current-command))
                   :description (lambda ()
                                  (let ((val (symbol-value var)))
                                    (if (eq var 'scad-ts-preview-camera)
                                        doc
                                      (concat
                                       doc
                                       " "
                                       (unless (listp val)
                                         "(")
                                       (propertize
                                        (format "%s" val)
                                        'face
                                        'transient-value)
                                       (unless (listp val)
                                         ")")))))
                   :inapt-if-not
                   (lambda ()
                     (scad-ts-mode--custom-variable-changed-p var))))
           '(("-T" "theme" scad-ts-preview-colorscheme)
             ("-P" "projection" scad-ts-preview-projection)
             ("-V" "preview view" scad-ts-preview-view)
             ("-O" "camera orientation" scad-ts-preview-camera)
             ("-E" "Extra args" scad-ts-mode-openscad-extra-args)))
          (list '("S" scad-ts-save-variables
                  :inapt-if-not scad-ts--get-modified-variables
                  :description
                  (lambda ()
                    (concat "all changed variables "
                     (mapconcat (lambda (it)
                                  (propertize
                                   (substring-no-properties (symbol-name
                                                             it))
                                   'face
                                   'transient-value))
                      (scad-ts--get-modified-variables)
                      ", ")))))))


(defun scad-ts--preview-update-coords (x y z)
  "Update the camera preview's orientation coordinates.

This helper function takes three numeric parameters, each representing
an angle (in degrees), and updates the corresponding orientation values in
the global variable `scad-ts-preview-camera'. The function sets the 4th,
5th, and 6th elements of the list, which control the preview camera's
rotation.

Parameters:
  X - the angle (in degrees) to set as the first orientation coordinate.
  Y - the angle (in degrees) to set as the second orientation coordinate.
  Z - the angle (in degrees) to set as the third orientation coordinate."
  (let* ((vals (list x y z)))
    (dotimes (i (length vals))
      (let ((val (nth i vals)))
        (setf (nth (+ i 3) scad-ts-preview-camera)
              val)))))

(defun scad-ts--current-x-y-z ()
  "Return a subsequence of camera coordinates from indices 3 to 5."
  (seq-subseq scad-ts-preview-camera 3 6))

(defun scad-ts--update-coords-or-invoke (x y z alternative-fn &optional msg
                                              alternative-message)
  "Update the camera coordinates or invoke an alternative function.

X is a numeric value representing the first orientation coordinate.
Y is a numeric value representing the second orientation coordinate.
Z is a numeric value representing the third orientation coordinate.

ALTERNATIVE-FN is the function called when the current coordinates match X, Y,
and Z.

Optional MSG is a string displayed when the coordinates are updated.

Optional ALTERNATIVE-MESSAGE is a string displayed when ALTERNATIVE-FN is
called."
  (if (equal (scad-ts--current-x-y-z)
             (list x y z))
      (when scad-ts-preview-allow-reverse
        (funcall alternative-fn)
        (message (or alternative-message "Reversed")))
    (scad-ts--preview-update-coords x y z)
    (scad-ts-mode--preview-render)
    (when msg
      (message msg))))

(defun scad-ts-preview-top-view ()
  "Render the preview from a top view orientation.

Configures `scad-ts-preview-camera' to simulate a bird's-eye view,
where the viewpoint is directly above the object.

Example diagram (roughly):
   y
   |
   z---x

This view is useful for understanding the object's layout when viewed from
overhead."
  (interactive)
  (scad-ts--update-coords-or-invoke 0 0 0 #'scad-ts-preview-bottom-view
                                       "Top view"
                                       "Bottom view"))

(defun scad-ts-preview-bottom-view ()
  "Render the preview from a bottom view orientation.

Sets the camera orientation to display the scene from beneath the object,
providing an inverse perspective relative to the top view. Once the angles
are updated, the preview is rendered.

Example diagram (roughly):
   z---x
   |
   y

This view can help in visualizing undercuts or bottom details."
  (interactive)
  (scad-ts--update-coords-or-invoke 180 0 180 #'scad-ts-preview-top-view
                                    "Bottom view"
                                    "Top view"))

(defun scad-ts-preview-left-view ()
  "Render the preview from a left side view orientation.

Adjusts the camera so that the left side of the object is shown.
After updating the perspective angles, the preview is rendered.

Example diagram (roughly):
       z
       |
   y---x

This view gives insight into the left-facing features of the design."
  (interactive)
  (scad-ts--update-coords-or-invoke 90 0 270 #'scad-ts-preview-right-view
                                       "Left view"
                                       "Right view"))

(defun scad-ts-preview-right-view ()
  "Render the preview from a right side view orientation.

Updates the camera settings to display the right side of the object.
The orientation angles are set accordingly before invoking the preview
render command.

Example diagram (roughly):
   z
   |
   x---y

Use this view to inspect right-side details of your 3D model."
  (interactive)
  (scad-ts--update-coords-or-invoke 90 0 90 #'scad-ts-preview-left-view
                                       "Right view"
                                       "Left view"))

(defun scad-ts-preview-front-view ()
  "Render the preview from a front view orientation.

Modifies the camera orientation to a frontal perspective, showing the
face of the object. After updating the camera angles, the rendering
function is called to display the view.

Example diagram (roughly):
   z
   |
   y---x

This view is optimal for analyzing front-facing features."
  (interactive)
  (scad-ts--update-coords-or-invoke 90 0 0 #'scad-ts-preview-back-view
                                       "Front view"
                                       "Back view"))

(defun scad-ts-preview-back-view ()
  "Render the preview from a back view orientation.

Configures the preview camera to display the object from behind.
This is achieved by setting the proper camera angles and then rendering
the preview.

Example diagram (roughly):
       z
       |
   x---y

The back view is particularly useful for inspecting rear section details."
  (interactive)
  (scad-ts--update-coords-or-invoke 90 0 180 #'scad-ts-preview-front-view
                                    "Back view"
                                    "Front view"))

(defun scad-ts-preview--deg-to-rad (deg)
  "Convert DEG (in degrees) to radians."
  (/ (* deg float-pi) 180.0))

;;
;; We assume the Euler rotation order:
;;   1. Rotate by RX about X,
;;   2. then by RY about Y,
;;   3. then by RZ about Z.
;;
;; The individual matrices (with angles in radians) are:
;;
;;   Rx = [ 1    0       0      ]
;;        [ 0   cos(rx) -sin(rx)]
;;        [ 0   sin(rx)  cos(rx)]
;;
;;   Ry = [ cos(ry)  0  sin(ry)]
;;        [    0     1     0   ]
;;        [ -sin(ry) 0  cos(ry)]
;;
;;   Rz = [ cos(rz) -sin(rz) 0]
;;        [ sin(rz)  cos(rz) 0]
;;        [   0         0    1]
;;
;; The composite is R = Rz * Ry * Rx.
(defun scad-ts-preview--compute-rotation-matrix (rx ry rz)
  "Return the composite rotation matrix for rotations RX, RY, and RZ (in degrees).

The result is a list of 9 numbers (row-major order):
 [ r00 r01 r02
   r10 r11 r12
   r20 r21 r22 ]."
  (let* ((rxd (scad-ts-preview--deg-to-rad rx))
         (ryd (scad-ts-preview--deg-to-rad ry))
         (rzd (scad-ts-preview--deg-to-rad rz))
         (cx (cos rxd))
         (sx (sin rxd))
         (cy (cos ryd))
         (sy (sin ryd))
         (cz (cos rzd))
         (sz (sin rzd))
         ;;
         (r00 (* cz cy))
         (r01 (- (* cz (* sy sx))
                 (* sz cx)))
         (r02 (+ (* cz (* sy cx))
                 (* sz sx)))
         (r10 (* sz cy))
         (r11 (+ (* sz (* sy sx))
                 (* cz cx)))
         (r12 (- (* sz (* sy cx))
                 (* cz sx)))
         (r20 (- sy))
         (r21 (* cy sx))
         (r22 (* cy cx)))
    (list r00 r01 r02
          r10 r11 r12
          r20 r21 r22)))

(defun scad-ts-preview--vector-subtract (v1 v2)
  "Return the subtraction of 3D vector V2 from V1 (V1 - V2)."
  (list (- (nth 0 v1)
           (nth 0 v2))
        (- (nth 1 v1)
           (nth 1 v2))
        (- (nth 2 v1)
           (nth 2 v2))))

(defun scad-ts-preview--vector-scale (v s)
  "Scale 3D vector V by scalar S."
  (list (* (nth 0 v) s)
        (* (nth 1 v) s)
        (* (nth 2 v) s)))

(defun scad-ts-preview--extra-vector-dot (v1 v2)
  "Return the dot product of 3D vectors V1 and V2."
  (+ (* (nth 0 v1)
        (nth 0 v2))
     (* (nth 1 v1)
        (nth 1 v2))
     (* (nth 2 v1)
        (nth 2 v2))))

(defun scad-ts-preview--vector-cross (v1 v2)
  "Return the cross product of 3D vectors V1 and V2 (V1 × V2)."
  (list (- (* (nth 1 v1)
              (nth 2 v2))
           (* (nth 2 v1)
              (nth 1 v2)))
        (- (* (nth 2 v1)
              (nth 0 v2))
           (* (nth 0 v1)
              (nth 2 v2)))
        (- (* (nth 0 v1)
              (nth 1 v2))
           (* (nth 1 v1)
              (nth 0 v2)))))

(defun scad-ts-preview--vector-norm (v)
  "Return the Euclidean norm (length) of 3D vector V."
  (sqrt (scad-ts-preview--extra-vector-dot v v)))

(defun scad-ts-preview--vector-normalize (v)
  "Return a normalized copy of the 3D vector V.

If V is too small, return V unchanged."
  (let ((norm (scad-ts-preview--vector-norm v)))
    (if (> norm 1e-8)
        (scad-ts-preview--vector-scale v (/ 1.0 norm))
      v)))

;;
(defun scad-ts-preview--compute-screen-basis ()
  "Return plist with keys :forward, :right, :left, and :up for onscreen directions.

The values are computed from the camera’s rotation in `scad-ts-preview-camera'
positions 3-5."
  (let* ((rx (nth 3 scad-ts-preview-camera))
         (ry (nth 4 scad-ts-preview-camera))
         (rz (nth 5 scad-ts-preview-camera))
         (mat (scad-ts-preview--compute-rotation-matrix rx ry rz))
         (r02 (nth 2 mat))
         (r12 (nth 5 mat))
         (r22 (nth 8 mat))
         (forward-raw (list (- r02)
                            (- r12)
                            (- r22)))
         (forward (scad-ts-preview--vector-normalize forward-raw))
         (world-up '(0 0 1))
         (dot (scad-ts-preview--extra-vector-dot world-up forward))
         (proj (scad-ts-preview--vector-scale forward dot))
         (screen-up-raw (scad-ts-preview--vector-subtract world-up proj))
         (screen-up (if (< (scad-ts-preview--vector-norm screen-up-raw) 1e-3)
                        (if (< (nth 2 forward) 0)
                            '(0 -1 0)
                          '(0 1 0))
                      (scad-ts-preview--vector-normalize screen-up-raw)))
         (right-raw (scad-ts-preview--vector-cross screen-up forward))
         (right (scad-ts-preview--vector-normalize right-raw))
         (left (scad-ts-preview--vector-scale right -1)))
    (list
     :forward forward
     :up screen-up
     :right right
     :left left)))

(defun scad-ts-preview--apply-translation (dir step)
  "Add a translation along the 3D direction vector DIR scaled by STEP."
  (let* ((tx (nth 0 scad-ts-preview-camera))
         (ty (nth 1 scad-ts-preview-camera))
         (tz (nth 2 scad-ts-preview-camera))
         (dx (* (nth 0 dir) step))
         (dy (* (nth 1 dir) step))
         (dz (* (nth 2 dir) step)))
    (setf (nth 0 scad-ts-preview-camera)
          (+ tx dx))
    (setf (nth 1 scad-ts-preview-camera)
          (+ ty dy))
    (setf (nth 2 scad-ts-preview-camera)
          (+ tz dz))
    (scad-ts-mode--preview-render)))

(defun scad-ts-preview-translate-left (&optional step)
  "Translate the camera to the left by STEP in a screen-aligned way.

Optional argument STEP specifies the translation step size.

If not provided, it defaults to the value of
`scad-ts-preview-translation-step'."
  (interactive (list
                (when current-prefix-arg
                  (prefix-numeric-value
                   current-prefix-arg)))
               scad-ts-preview-mode)
  (let* ((step (or step scad-ts-preview-translation-step))
         (basis (scad-ts-preview--compute-screen-basis))
         (raw-rx (nth 3 scad-ts-preview-camera))
         (rx (mod raw-rx 360))
         (left (plist-get basis (if (< 0 rx 180)
                                    :right
                                  :left))))
    (scad-ts-preview--apply-translation left step)))

(defun scad-ts-preview-translate-right (&optional step)
  "Translate the camera to the right by STEP in a screen-aligned way.

Optional argument STEP specifies the translation step size.

If not provided, it defaults to the value
of `scad-ts-preview-translation-step'."
  (interactive (list
                (when current-prefix-arg
                  (prefix-numeric-value
                   current-prefix-arg)))
               scad-ts-preview-mode)
  (let* ((step (or step scad-ts-preview-translation-step))
         (basis (scad-ts-preview--compute-screen-basis))
         (raw-rx (nth 3 scad-ts-preview-camera))
         (rx (mod raw-rx 360))
         (right (plist-get basis (if (< 0 rx 180)
                                     :left
                                   :right))))
    (scad-ts-preview--apply-translation right step)))

(defun scad-ts-preview-translate-up (&optional step)
  "Translate the camera upward by STEP in a screen-aligned way.

Optional argument STEP specifies the translation step size.

If not provided, it defaults to the value
of `scad-ts-preview-translation-step'."
  (interactive (list
                (when current-prefix-arg
                  (prefix-numeric-value
                   current-prefix-arg)))
               scad-ts-preview-mode)
  (let* ((step (or step scad-ts-preview-translation-step))
         (basis (scad-ts-preview--compute-screen-basis))
         (raw-rx (nth 3 scad-ts-preview-camera))
         (rx (mod raw-rx 360))
         (up (plist-get basis :up)))
    (scad-ts-preview--apply-translation up
                                        (if (< 0 rx 180)
                                            step
                                          (-
                                           step)))))

(defun scad-ts-preview-translate-down (&optional step)
  "Translate the camera downward by STEP in a screen-aligned way.

Optional argument STEP specifies the translation step size.

If not provided, it defaults to the value
of `scad-ts-preview-translation-step'."
  (interactive (list
                (when current-prefix-arg
                  (prefix-numeric-value
                   current-prefix-arg)))
               scad-ts-preview-mode)
  (let ((step (or step scad-ts-preview-translation-step)))
    (scad-ts-preview-translate-up (- step))))

(defun scad-ts-preview-translate-forward (&optional step)
  "Translate the camera forward by STEP.

Optional argument STEP specifies the translation step size.

If not provided, it defaults to the value of
`scad-ts-preview-translation-step'."
  (interactive (list
                (when current-prefix-arg
                  (prefix-numeric-value
                   current-prefix-arg)))
               scad-ts-preview-mode)
  (let* ((step (or step scad-ts-preview-translation-step))
         (basis (scad-ts-preview--compute-screen-basis))
         (forward (plist-get basis :forward)))
    (scad-ts-preview--apply-translation forward step)))

(defun scad-ts-preview-translate-backward (&optional step)
  "Translate the camera backward by STEP.

Optional argument STEP specifies the translation step size.

If not provided, it defaults to the value of
`scad-ts-preview-translation-step'."
  (interactive  (list
                 (when current-prefix-arg
                   (prefix-numeric-value
                    current-prefix-arg))))
  (let ((step (or step scad-ts-preview-translation-step)))
    (scad-ts-preview-translate-forward (- step))))


(defun scad-ts-show-output-logs ()
  "Display the preview output buffer, or signal an error if missing."
  (interactive)
  (let ((buff (get-buffer scad-ts-mode--preview-output-buffer-name)))
    (if (not (buffer-live-p buff))
        (user-error "No output buffer")
      (unless (get-buffer-window buff)
        (display-buffer
         buff '(nil (inhibit-same-window . t)))))))

(defun scad-ts--setup-preview-menu ()
  "Build preview menu suffixes by parsing help and defining view/enable toggles."
  (scad-ts--openscad-help)
  (unless scad-ts--view-suffixes
    (setq scad-ts--view-suffixes
          (mapcar (lambda (value)
                    (let ((key (concat "-"
                                       (substring-no-properties value 0 1)))
                          (doc value))
                      (let ((sym (make-symbol (concat
                                               "scad-ts--toggle-"
                                               value))))
                        (defalias sym
                          (lambda ()
                            (interactive)
                            (let ((next-val
                                   (if
                                       (member
                                        value
                                        scad-ts-preview-view)
                                       (remove
                                        value
                                        scad-ts-preview-view)
                                     (append
                                      scad-ts-preview-view
                                      (list
                                       value)))))
                              (cond ((derived-mode-p
                                      'scad-ts-preview-mode)
                                     (setq-local scad-ts-preview-view next-val)
                                     (scad-ts-mode--preview-render))
                                    (t
                                     (setq scad-ts-preview-view next-val)))
                              (transient-setup
                               transient-current-command)))
                          doc)
                        (list key sym
                              :description
                              (lambda ()
                                (let* ((active (member
                                                value scad-ts-preview-view))
                                       (inapt (and active
                                                   (= 1
                                                      (length
                                                       scad-ts-preview-view))))
                                       (descr (scad-ts--format-toggle
                                               value
                                               active)))
                                  (if inapt
                                      (propertize descr 'face
                                                  'transient-inapt-argument)
                                    descr)))))))
                  (car (last
                        (assoc-string "--view"
                                      scad-ts-preview--openscad-help-cache))))))
  (unless scad-ts--enable-suffixes
    (setq scad-ts--enable-suffixes
          (let* ((vals (car (last
                             (assoc-string
                              "--enable"
                              scad-ts-preview--openscad-help-cache))))
                 (longest (+ 5
                             (apply #'max
                                    (or
                                     (mapcar #'length vals)
                                     '(20))))))
            (mapcar
             (lambda (value)
               (let ((key (concat "-"
                                  (substring-no-properties value 0 1)))
                     (doc value)
                     (arg (format "--enable=%s" value)))
                 (let ((sym (make-symbol (concat
                                          "scad-ts--toggle-enable-"
                                          value))))
                   (defalias sym
                     (lambda ()
                       (interactive)
                       (let ((next-val
                              (if
                                  (member
                                   arg
                                   scad-ts-mode-openscad-extra-args)
                                  (remove
                                   arg
                                   scad-ts-mode-openscad-extra-args)
                                (append
                                 scad-ts-mode-openscad-extra-args
                                 (list
                                  arg)))))
                         (cond ((derived-mode-p
                                 'scad-ts-preview-mode)
                                (setq-local scad-ts-mode-openscad-extra-args
                                            next-val)
                                (scad-ts-mode--preview-render))
                               (t
                                (setq scad-ts-mode-openscad-extra-args
                                      next-val)))
                         (transient-setup
                          transient-current-command)))
                     doc)
                   (list key
                         sym
                         :description
                         (lambda ()
                           (let* ((active
                                   (member
                                    arg
                                    scad-ts-mode-openscad-extra-args))
                                  (descr (scad-ts--format-toggle
                                          value
                                          active
                                          nil
                                          nil
                                          nil
                                          nil
                                          nil
                                          longest)))
                             descr))))))
             vals)))))


;;;###autoload (autoload 'scad-ts-preview-menu "scad-ts" nil t)
(transient-define-prefix scad-ts-preview-menu ()
  "Provide a transient menu for `scad-ts-preview-mode'."
  [:description
   (lambda ()
     (scad-ts--format-menu-heading
      "Scad-ts preview"
      (when (derived-mode-p 'scad-ts-preview-mode)
        scad-ts-mode--preview-mode-camera)))
   :if-derived scad-ts-preview-mode
   ["Translate"
    ("M-<up>" "Up" scad-ts-preview-translate-up :transient t)
    ("M-<down>" "Down" scad-ts-preview-translate-down :transient t)
    ("M-<left>" "Left" scad-ts-preview-translate-left :transient t)
    ("M-<right>" "Right" scad-ts-preview-translate-right :transient t)
    ("B" "Backward" scad-ts-preview-translate-backward :transient t)
    ("F" "Forward" scad-ts-preview-translate-forward :transient t)]
   ["Rotate"
    ("t" "Top"  scad-ts-preview-top-view :transient t)
    ("b" "Bottom" scad-ts-preview-bottom-view :transient t)
    ("r" "Right" scad-ts-preview-right-view :transient t)
    ("l" "Left" scad-ts-preview-left-view :transient t)
    ("f" "Front" scad-ts-preview-front-view :transient t)
    ("b" "Back" scad-ts-preview-back-view :transient t)]
   [:description
    "View"
    :class transient-column
    :setup-children
    (lambda (&rest _argsn)
      (mapcar
       (apply-partially #'transient-parse-suffix
                        (oref transient--prefix command))
       (append scad-ts--display-options-suffixes
               scad-ts--view-suffixes)))]
   [:description
    "Enable"
    :class transient-column
    :setup-children
    (lambda (&rest _argsn)
      (mapcar
       (apply-partially #'transient-parse-suffix
                        (oref transient--prefix command))
       scad-ts--enable-suffixes))]
   ["Save"
    :class transient-column
    :setup-children
    (lambda (&rest _argsn)
      (mapcar
       (apply-partially #'transient-parse-suffix
                        (oref transient--prefix command))
       scad-ts--saveable-options))]]
  (interactive)
  (scad-ts--setup-preview-menu)
  (transient-setup #'scad-ts-preview-menu))

;;;###autoload
(define-minor-mode scad-ts-reload-preview-mode
  "Toggle automatic reloading of related SCAD preview buffers on save.

When enabled, saving a SCAD source file automatically triggers a refresh of any
visible preview buffers that display SCAD files which import the saved file.
This ensures that changes in any included files are immediately reflected in
the rendered views without requiring manual intervention.

Example:
  1. A SCAD file (e.g., one defining design parameters) is open in a buffer.
  2. Another SCAD file that imports the parameter file via an `include' or `use'
     statement is also open, with its preview buffer visible.
  3. When any changes are made to the parameter file and it is saved, the
     preview buffer of the importing file automatically re-renders to
     incorporate the updates."
  :lighter " sc-reload"
  :global nil
  (if scad-ts-reload-preview-mode
      (add-hook 'after-save-hook
                #'scad-ts--reload-related-preview-buffer nil 'local)
    (remove-hook 'after-save-hook
                 #'scad-ts--reload-related-preview-buffer 'local)))


(defvar-keymap scad-ts-mode-map
  :doc "Keymap for `scad-ts-mode'."
  :parent prog-mode-map
  "C-c C-c" #'scad-ts-mode-preview
  "C-h C-e" #'scad-ts-show-output-logs)

;;;###autoload
(define-derived-mode scad-ts-mode prog-mode "OpenSCAD"
  "Major mode for editing OpenSCAD using tree-sitter."
  :group 'scad-ts
  :keymap 'scad-ts-mode-map
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
