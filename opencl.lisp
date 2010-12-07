(in-package #:cl-opencl)

;; todo: organize these better?

;;; 4.3 contexts

(defmacro check-errcode-arg (form)
  (let ((error-code (gensym))
        (ret (gensym)))
    `(with-foreign-object (,error-code '%cl::error-code)
       (let ((,ret (,@form ,error-code)))
         (setf ,error-code (mem-aref ,error-code '%cl::error-code))
         (if (eq :success ,error-code)
             ,ret
             (error "OpenCL error ~s from ~s" ,error-code ',form))))))

;; todo: error callback, better handling of properties stuff
;; properties arg is ugly since it mixes pointers with enums
;; only one option though, so handling it explicitly for now
(defun create-context (devices &key platform)
  (let ((properties nil))
    (when platform
      (push (pointer-address platform) properties)
      (push :platform properties))
    (with-foreign-objects ((props '%cl:intptr-t (* 2 (1+ (length properties))))
                           (devs '%cl:device-id (length devices)))
      (loop for i from 0
         for dev in devices
         do (setf (mem-aref devs '%cl:device-id i) dev))
     (loop
        for i from 0 by 2 ;; step before list so FINALLY sees correct values
        for (p v) on properties by #'cddr
        do
        (setf (mem-aref props '%cl:context-properties i) p)
        (setf (mem-aref props '%cl:intptr-t (1+ i)) v)
        finally (progn
                  (setf (mem-aref props '%cl:intptr-t i) 0)
                  (setf (mem-aref props '%cl:intptr-t (1+ i)) 0)))
     (check-errcode-arg
      (%cl:create-context props (length devices) devs
                             ;; todo: error callback
                             (cffi:null-pointer) (cffi:null-pointer))))))

(defmacro with-opencl-plist ((var type properties) &body body)
  (let ((base-type (cffi::canonicalize-foreign-type type)))
    `(with-foreign-object (,var ',base-type (* 2 (1+ (length ,properties))))
       (loop
          for i from 0 by 2 ;; step before list so FINALLY sees correct values
          for (p v) on ,properties by #'cddr
          do
            (setf (mem-aref ,var ',type i) p)
            (setf (mem-aref ,var ',base-type (1+ i)) v)
          finally (progn
                    (setf (mem-aref ,var ',base-type i) 0)
                    (setf (mem-aref ,var ',base-type (1+ i)) 0)))
       ,@body)))

(defun create-context-from-type (type &key platform)
  (let ((properties nil))
    (when platform
      (push (pointer-address platform) properties)
      (push :platform properties))
    (with-opencl-plist (props %cl:context-properties properties)
      (check-errcode-arg
       (%cl:create-context-from-type props type
                                     ;; todo: error callback
                                     (cffi:null-pointer) (cffi:null-pointer))))))

(defun retain-context (context)
  (check-return (%cl:retain-context context))
  ;; not sure if returning context here is useful or if it should just return
  ;; :success fom the low-level call?
  context)

(defun release-context (context)
  (check-return (%cl:release-context context)))

(defmacro with-context ((context devices &rest properties) &body body)
  `(let ((,context (create-context ,devices ,@properties)))
     (unwind-protect
          (progn
            ,@body)
       (release-context ,context))))

(defmacro with-context-from-type ((context type &rest properties) &body body)
  `(let ((,context (create-context-from-type ,type ,@properties)))
     (unwind-protect
          (progn
            ,@body)
       (release-context ,context))))



;;;; 5.1 command queues

(defun create-command-queue (context device &rest properties
                             &key out-of-order-exec-mode-enable
                             profiling-enable)
  (declare (ignore out-of-order-exec-mode-enable profiling-enable))
  (check-errcode-arg (%cl:create-command-queue context device properties)))

(defun retain-command-queue (command-queue)
  (check-return (%cl:retain-command-queue command-queue))
  command-queue)

(defun release-command-queue (command-queue)
  (check-return (%cl:release-command-queue command-queue)))

(defun set-command-queue-property (command-queue properties enable &key return-old-properties)
  (if return-old-properties
      (with-foreign-object (old '%cl:command-queue-properties)
        (check-return (%cl:set-command-queue-property command-queue
                                                      properties enable old))
        (mem-aref old '%cl:command-queue-properties)
        #++(foreign-bitfield-symbols '%cl:command-queue-properties old))

      (check-return (%cl:set-command-queue-property command-queue
                                                    properties enable
                                                    (cffi:null-pointer)))))




;;;; 5.2 Memory Objects

;;; 5.2.1 Creating Buffer Objects

;; fixme: should this support preallocated host memory area?
;; skipping for now, since it exposes ffi level stuff...
;; possibly just support copy-host-ptr mode, with copy from lisp array?
(defun create-buffer (context size &rest flags)
  (check-errcode-arg (%cl:create-buffer context flags size (cffi:null-pointer))))

;; should size/count be implicit from array size?
;; foreign type?
;; switch to keywords instead of using &rest for flags?
(defun create-buffer-from-array (context array count foreign-type &rest flags)
  (with-foreign-object (buf foreign-type count)
    (loop repeat count
       for i below (array-total-size array)
       do (setf (mem-aref buf foreign-type i) (row-major-aref array i)))
    (check-errcode-arg
     (%cl:create-buffer context (adjoin :copy-host-pointer flags)
                        (* count (foreign-type-size foreign-type))
                        buf))))

(defparameter *lisp-type-map*
  (alexandria:plist-hash-table '(single-float :float
                                 double-float :double
                                 (unsigned-byte 8) :unsigned-char
                                 (signed-byte 8) :signed-char
                                 (unsigned-byte 16) :unsigned-short
                                 (signed-byte 16) :signed-short
                                 (unsigned-byte 32) :unsigned-int32
                                 (signed-byte 32) :signed-int32)
                               :test 'equal))
;;; 5.2.2 Reading, Writing and Copying Buffer Objects
(defun enqueue-read-buffer (command-queue buffer count
                            &key (blockp t) wait-list event
                            (offset 0) (element-type 'single-float))
  (let* ((foreign-type (gethash element-type *lisp-type-map*))
         (octet-count (* count (foreign-type-size foreign-type)))
         (array (make-array octet-count
                            :element-type element-type)))
    (when (or event wait-list)
      (error "events and wait lists not done yet in enqueue-read-buffer"))
    (unless blockp
      (error "non-blocking enqueue-read-buffer doesn't work yet"))
    ;; w-p-t-v-d won't work with non-blocking read...
    (with-pointer-to-vector-data (p array)
      (check-return (%cl:enqueue-read-buffer command-queue buffer blockp
                                             offset octet-count p
                                             0 (null-pointer) (null-pointer))))
    array))

;;; 5.3.3
#++
(defmacro with-size-t-3 ((var source &optional (default 0)) &body body)
  (let ((i (gensym)))
    (alexandria:once-only (source default)
      `(with-foreign-object (,var '%cl:size-t 3)
         (loop for ,i below 3
            for v = (if (< ,i (length ,source))
                        (elt ,source 1)
                        ,default)
            do (setf (mem-aref ,var '%cl:size-t ,i) v))
         ,@body))))

#++
(defmacro with-size-t-3s (bindings &body body)
  (if bindings
      `(with-size-t-3 ,(car bindings)
         (with-size-t-3s ,(cdr bindings)
           ,@body))
      `(progn ,@body)))


#++(defun enqueue-read-image (command-queue image dimensions
                            &key (blockp t) wait-list event
                            (origin '(0 0 0)) (element-type 'single-float)
                            (row-pitch 0) (slice-pitch 0))
  (let* ((foreign-type (ecase element-type
                         (single-float :float)))
         (array (make-array count :element-type element-type)))
    (with-pointer-to-vector-data (p array)
      (with-size-t-3s ((dimensions dimensions 1)
                       (origin origin 0))
        (check-return (%cl:enqueue-read-buffer command-queue buffer blockp
                                               origin )))
      ))
)

;;; 5.4.1 retaining and Releasing Memory Objects

(defun retain-mem-object (object)
  (check-return (%cl:retain-mem-object object))
  object)

(defun release-mem-object (object)
  (check-return (%cl:release-mem-object object)))

;; set-mem-object-destructor-callback

;;; 5.4.4 Memory Object Queries - see get.lisp


;;; 5.6.1 Creating Program Objects

(defun create-program-with-source (context &rest strings)
  ;; fixme: avoid this extra copy of the string data..
  ;; either pass the concatenated string directly (maybe concatenating
  ;;  into an octet array instead of a string?) or allocate separate
  ;;  buffers for each string
  (let ((string (if (= 1 (length strings))
                    (car strings)
                    (format nil "~{~a~}" strings))))
    (with-foreign-string (cstring string)
      (with-foreign-object (p :pointer)
        (setf (mem-ref p :pointer) cstring)
       (check-errcode-arg (%cl:create-program-with-source context 1 p
                                                          (null-pointer)))))))

;; todo: create-program-with-binary

(defun retain-program (program)
  (check-return (%cl:retain-program program))
  program)

(defun release-program (program)
  (check-return (%cl:release-program program)))

;;; 5.6.2 Building Program Executables

;; todo: add notify callback support
;;  - requiring callers to pass a cffi callback is a bit ugly
;;  - using an interbal cffi callback and trying to map back to caller's
;;    lisp callback is probably nicer API, but harder to implement
;;  - also need to deal with thread safety stuff... not sure if it might
;;    be called from arbitrary threads or not
;; todo: add keywords for know options?
(defun build-program (program &key devices (options-string "")
                      #++ notify-callback)
  (with-foreign-object (device-list :pointer (length devices))
    (with-foreign-string (options options-string)
     (check-return (%cl:build-program program (length devices)
                                      (if devices device-list (null-pointer))
                                      options-string
                                      (null-pointer) (null-pointer))
       (:build-program-failure
        (let ((status (loop for i in (get-program-info program :devices)
                         collect (list (get-program-build-info program i :status)
                                       (get-program-build-info program i :log)))))
          (error "Build-program returned :buld-program-failure:~:{~&~s : ~s~}" status))))))
)

;;; 5.6.4 Unloading the OpenCL Compiler

(defun unload-compiler ()
  (check-return (%cl:unload-compiler)))

;;; 5.6.5 Program Object Queries - see get.lisp

;;; 5.7.1 Creating Kernel Objects

(defun create-kernel (program name)
  (check-errcode-arg (%cl:create-kernel program name)))

(defun create-kernels-in-program (program)
  ;; fixme: verify calling this twice is the correct way to figure out
  ;; how many kernels are in program...
  (get-counted-list %cl:create-kernels-in-program (program) '%cl:kernel))

(defun retain-kernel (kernel)
  (check-return (%cl:retain-kernel kernel))
  kernel)

(defun release-kernel (kernel)
  (check-return (%cl:release-kernel kernel)))

;;; 5.7.2 Setting Kernel Arguments

;;; fixme: set-kernel-arg is ugly, since we don't have enough C style
;;;   static type info, or lisp style dynamic info to determine
;;;   anything useful about the arg values...

;;; probably want some combination of wrapping the various low-level
;;;   binding types (buffers, images etc) in clos wrappers so we can
;;;   introspect those for type/size, and statically typed ffi definitions
;;;   for kernels so we can do type conversions for things like numbers

;;; for now, just breaking into a few specific functions, and using function
;;;   name to encode static type info...
(defun %set-kernel-arg-buffer (kernel index buffer)
  (with-foreign-object (p :pointer)
    (setf (mem-ref p :pointer) buffer)
    (check-return (%cl:set-kernel-arg kernel index (foreign-type-size '%cl:mem) p))))
(defun %set-kernel-arg-image (kernel index image)
  (check-return (%cl:set-kernel-arg kernel index (foreign-type-size '%cl:sampler) image)))

(defun %set-kernel-arg-number (kernel index value type)
  (with-foreign-object (p type)
    (setf (mem-ref p type) value)
    (check-return (%cl:set-kernel-arg kernel index (foreign-type-size type) p))))


;;; 5.8 Executing Kernels
(defmacro with-foreign-array ((name type source &key max empty-as-null-p) &body body)
  (let ((p (gensym)))
    (alexandria:once-only (type source)
      `(with-foreign-object (,p ,type ,@(if max
                                            `((min ,max (length ,source)))
                                            `((length ,source))))
         (let ((i 0))
           (map 'nil (lambda (v)
                       (setf (mem-aref ,p ,type i) v)
                       (incf i))
                ,source))
         (let ((,name ,@(if empty-as-null-p
                            `((if (zerop (length ,source))
                                 (null-pointer)
                                 ,p))
                            `(,p))))
           ,@body)))))

(defmacro with-foreign-arrays (bindings &body body)
  (if bindings
      `(with-foreign-array ,(car bindings)
         (with-foreign-arrays ,(cdr bindings)
           ,@body))
      `(progn ,@body)))

;; not sure about the API here...
;; for now requiring global-size, and getting dimensions from legth of that
(defun enqueue-nd-range-kernel (command-queue kernel global-size
                                &key global-offset local-size)
  (let ((dims (min (length global-size) 3)))
    (with-foreign-arrays ((global-size '%cl:size-t global-size :max 3)
                          (global-offset '%cl:size-t global-offset :max 3 :empty-as-null-p t)
                          (local-size '%cl:size-t local-size :max 3 :empty-as-null-p t))
      (check-return
          (%cl:enqueue-nd-range-kernel command-queue kernel dims global-offset
                                       global-size local-size
                                       0 (null-pointer)
                                       (null-pointer)
 )))
)

)



;;; 5.13 Flush and Finish

(defun flush (command-queue)
  (check-return (%cl:flush command-queue)))

(defun finish (command-queue)
  (check-return (%cl:finish command-queue)))