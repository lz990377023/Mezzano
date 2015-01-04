(defpackage :mezzanine.gui.font
  (:use :cl)
  (:export #:with-font
           #:open-font
           #:close-font
           #:name
           #:size
           #:line-height
           #:em-square-width
           #:ascender
           #:glyph-character
           #:glyph-mask
           #:glyph-yoff
           #:glyph-xoff
           #:glyph-advance
           #:character-to-glyph
           #:*default-font*
           #:*default-font-size*
           #:*default-monospace-font*
           #:*default-monospace-font-size*))

(in-package :mezzanine.gui.font)

(defvar *default-font* "DejaVuSans")
(defvar *default-font-size* 12)
(defvar *default-monospace-font* "DejaVuSansMono")
(defvar *default-monospace-font-size* 12)

(defclass typeface ()
  ((%font-loader :initarg :font-loader :reader font-loader)
   (%name :initarg :name :reader name)
   (%refcount :initform 1)))

(defclass font ()
  ((%typeface :initarg :typeface :reader typeface)
   (%font-size :initarg :size :reader size)
   (%font-scale :reader font-scale)
   (%line-height :reader line-height)
   (%em-square-width :reader em-square-width)
   (%font-ascender :reader ascender)
   ;; Not protected by a lock. Multiple threads racing just do extra work, nothing incorrect.
   (%glyph-cache :reader glyph-cache)
   (%refcount :initform 1)))

(defmethod print-object ((typeface typeface) stream)
  (print-unreadable-object (typeface stream :type t :identity t)
    (format stream "~S" (name typeface))))

(defmethod print-object ((font font) stream)
  (print-unreadable-object (font stream :type t :identity t)
    (format stream "~S ~S" (name font) (size font))))

(defmethod name ((font font))
  (name (typeface font)))

(defmethod font-loader ((font font))
  (font-loader (typeface font)))

(defstruct glyph
  ;; Lisp character this glyph represents.
  character
  ;; 8-bit alpha mask for this glyph.
  mask
  ;; Y offset from baseline.
  yoff
  ;; X offset from pen position.
  xoff
  ;; Total width of this character.
  advance)

(defvar *font-lock* (mezzanine.supervisor:make-mutex "Font lock")
  "Lock protecting the typeface and font caches.")

;; font-name (lowercase) -> typeface
(defvar *typeface-cache* (make-hash-table :test 'equal))
;; (lowercase font name . single-float size) -> font
(defvar *font-cache* (make-hash-table :test 'equal))

(defun path-map-line (path function)
  "Iterate over all the line on the contour of the path."
  (loop with iterator = (paths:path-iterator-segmented path)
     for previous-knot = nil then knot
     for (interpolation knot end-p) = (multiple-value-list (paths:path-iterator-next iterator))
     while knot
     when previous-knot
     do (funcall function previous-knot knot)
     until end-p
     finally (when knot
               (funcall function knot (nth-value 1 (paths:path-iterator-next iterator))))))

(defun rasterize-paths (paths sweep-function &optional (scale 1.0))
  (let ((state (aa:make-state)))
    (flet ((do-line (p1 p2)
             (aa:line-f state
                        (* scale (paths:point-x p1)) (* scale (paths:point-y p1))
                        (* scale (paths:point-x p2)) (* scale (paths:point-y p2)))))
      (loop for path in paths
         do (path-map-line path #'do-line)))
    (aa:cells-sweep state sweep-function)))

(defun normalize-alpha (alpha)
  (min 255 (abs alpha)))

(defun scale-bb (bb scale)
  (vector (floor (* (zpb-ttf:xmin bb) scale)) (floor (* (zpb-ttf:ymin bb) scale))
          (ceiling (* (zpb-ttf:xmax bb) scale)) (ceiling (* (zpb-ttf:ymax bb) scale))))

(defun rasterize-glyph (glyph scale)
  (let* ((bb (scale-bb (zpb-ttf:bounding-box glyph) scale))
         (width (- (zpb-ttf:xmax bb) (zpb-ttf:xmin bb)))
         (height (- (zpb-ttf:ymax bb) (zpb-ttf:ymin bb)))
         (array (make-array (list height width)
                            :element-type '(unsigned-byte 8)
                            :initial-element 0))
         (paths (paths-ttf:paths-from-glyph glyph
                                            :scale-x scale
                                            :scale-y (- scale)
                                            :offset (paths:make-point 0 (zpb-ttf:ymax bb))
                                            :auto-orient :cw)))
    (rasterize-paths paths (lambda (x y alpha)
                             (setf (aref array y (- x (zpb-ttf:xmin bb)))
                                   (normalize-alpha alpha))))
    array))

(defun expand-bit-mask-to-ub8-mask (mask)
  (let ((new (make-array (array-dimensions mask) :element-type '(unsigned-byte 8))))
    (dotimes (y (array-dimension mask 0))
      (dotimes (x (array-dimension mask 1))
        (setf (aref new y x) (* #xFF (aref mask y x)))))
    new))

(defgeneric character-to-glyph (font character))

(defmethod character-to-glyph ((font font) character)
  ;; TODO: char-bits
  (let* ((code (char-code character))
         (plane (ash code -16))
         (cell (logand code #xFFFF))
         (main-cache (glyph-cache font))
         (cell-cache (aref main-cache plane)))
    (when (not cell-cache)
      (setf cell-cache (make-array (expt 2 16) :initial-element nil)
            (aref main-cache plane) cell-cache))
    (let ((glyph (aref cell-cache cell)))
      (when (not glyph)
        ;; Glyph does not exist in the cache, rasterize it.
        (cond ((zpb-ttf:glyph-exists-p code (font-loader font))
               (let* ((ttf-glyph (zpb-ttf:find-glyph code (font-loader font)))
                      (scale (font-scale font))
                      (bb (scale-bb (zpb-ttf:bounding-box ttf-glyph) scale))
                      (advance (round (* (zpb-ttf:advance-width ttf-glyph) scale))))
                 (setf glyph (make-glyph :character (code-char code)
                                         :mask (rasterize-glyph ttf-glyph scale)
                                         :yoff (zpb-ttf:ymax bb)
                                         :xoff (zpb-ttf:xmin bb)
                                         :advance advance)
                       (aref cell-cache cell) glyph)))
              (t ;; Use Unifont fallback.
               (let ((mask (or (sys.int::map-unifont-2d (code-char code))
                               (sys.int::map-unifont-2d #\WHITE_VERTICAL_RECTANGLE))))
                 (setf glyph (make-glyph :character (code-char code)
                                         :mask (expand-bit-mask-to-ub8-mask mask)
                                         :yoff 14
                                         :xoff 0
                                         :advance (array-dimension mask 1))
                       (aref cell-cache cell) glyph)))))
      glyph)))

(defmethod initialize-instance :after ((font font) &key typeface size &allow-other-keys)
  (let ((loader (font-loader typeface)))
    (setf (slot-value font '%font-scale) (/ size (float (zpb-ttf:units/em loader)))
          (slot-value font '%line-height) (round (* (+ (zpb-ttf:ascender loader)
                                                       (- (zpb-ttf:descender loader))
                                                       (zpb-ttf:line-gap loader))
                                                    (font-scale font)))
          (slot-value font '%em-square-width) (round (* (+ (zpb-ttf:xmax (zpb-ttf:bounding-box loader))
                                                           (- (zpb-ttf:xmin (zpb-ttf:bounding-box loader))))
                                                        (font-scale font)))
          (slot-value font '%font-ascender) (round (* (zpb-ttf:ascender loader)
                                                      (font-scale font)))
          (slot-value font '%glyph-cache) (make-array 17 :initial-element nil))))

(defun find-font (name &optional (errorp t))
  "Return the truename of the font named NAME"
  (truename (make-pathname :name name :type "ttf" :defaults "LOCAL:>Fonts>" #+(or)"SYS:FONTS;")))

(defun open-font (name size)
  (check-type name (or string symbol))
  (check-type size real)
  (let* ((typeface-key (string-downcase name))
         (font-key (cons typeface-key (float size))))
    (mezzanine.supervisor:with-mutex (*font-lock*)
      (let ((font (gethash font-key *font-cache*)))
        (when font
          (incf (slot-value font '%refcount))
          (return-from open-font font))
        ;; No font object, create a new one.
        (let ((typeface (gethash typeface-key *typeface-cache*)))
          (when typeface
            (incf (slot-value typeface '%refcount))
            (setf font (make-instance 'font
                                      :typeface typeface
                                      :size (float size))
                  (gethash font-key *font-cache*) font)
            (format t "Creating new font ~S with typeface ~S.~%" font typeface)
            (return-from open-font font)))))
    ;; Neither font nor typeface in cache. Open the TTF outside the lock
    ;; to signalling lock held.
    (let ((loader (zpb-ttf:open-font-loader (find-font name))))
      (mezzanine.supervisor:with-mutex (*font-lock*)
        ;; Repeat font test.
        (let ((font (gethash font-key *font-cache*)))
          (when font
            (incf (slot-value font '%refcount))
            (return-from open-font font)))
        (let ((typeface (gethash typeface-key *typeface-cache*)))
          (cond (typeface
                 ;; A typeface was created for this font while the lock
                 ;; was dropped. Forget our font loader and use this one.
                 (zpb-ttf:close-font-loader loader)
                 (incf (slot-value typeface '%refcount)))
                (t (setf typeface (make-instance 'typeface :name (format nil "~:(~A~)" name) :font-loader loader)
                         (gethash typeface-key *typeface-cache*) typeface)
                   (format t "Creating new typeface ~S.~%" typeface)))
          (let ((font (make-instance 'font
                                     :typeface typeface
                                     :size (float size))))
            (format t "Creating new font ~S with typeface ~S.~%" font typeface)
            (setf (gethash font-key *font-cache*) font)
            font))))))

(defun close-font (font)
  (mezzanine.supervisor:with-mutex (*font-lock*)
    (decf (slot-value font '%refcount))
    (when (zerop (slot-value font '%refcount))
      ;; Flush this font, and release the typeface.
      (remhash (cons (string-downcase (name font)) (size font)) *font-cache*)
      (let ((typeface (typeface font)))
        (decf (slot-value typeface '%refcount))
        (when (zerop (slot-value typeface '%refcount))
          (remhash (string-downcase (name font)) *typeface-cache*))))))

(defmacro with-font ((font name size) &body body)
  `(let (,font)
    (unwind-protect
         (progn
           (setf ,font (open-font ,name ,size))
           ,@body)
      (when ,font
        (close-font ,font)))))