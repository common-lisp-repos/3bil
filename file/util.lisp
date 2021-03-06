(in-package :avm2-compiler)

;; pieces shared between both writers

;;; fixme: deal with package stuff, possibly reorganize stuff between asm/compiler...

(defun super-names (name)
  (let ((c (when name (find-swf-class name))))
    (when c
      (cons (swf-name c) (super-names (extends c))))))

(defun push-lex-scope (mn-index)
  `((:get-lex ,(if (integerp mn-index) `(:id ,mn-index)mn-index))
    (:push-scope)))

(defun new-class+scopes (class)
  ;; fixme: allow class lookup instead of using class-id directly?
  (let ((supers (reverse (super-names (extends class)))))
    (unless (second (assoc (swf-name class) (class-names *compiler-context*)))
      (break "name ~s = ~s names ~s" (swf-name class)
              (assoc (swf-name class) (class-names *compiler-context*))
              (class-names *compiler-context*)))
    `((:get-scope-object 0)
      ,@(loop for i in supers
           append (push-lex-scope i))
      (:get-lex ,(swf-name (find-swf-class (extends class))))
      (:new-class ,(second (assoc (swf-name class) (class-names *compiler-context*))))
      ,@(loop repeat  (length supers)
           collect `(:pop-scope))
      (:init-property  ,(swf-name class)))))

(defun intern-constant (x)
  (etypecase x
    ((integer 0 #.(expt 2 32))
     (cons (avm2-asm::avm2-intern-uint x) 4))
    ((integer #.(- (expt 2 31)) #.(expt 2 31))
     (cons (avm2-asm::avm2-intern-int x) 3))
    (number
     (cons (avm2-asm::avm2-intern-double (float x 0d0)) 6))
    (string
     (cons (avm2-asm::avm2-string x) 1))
    ((eql t)
     (cons 1 #x0b))
    ;;(false #x0a)
    ((eql nil)
     (cons 1 #x0c))
    #++(undef 0)
    #++(ns 8)
    #++(pks ns x16)
    #++(pkg internal ns x17)
    #++(prot ns x18)
    #++(explicit ns x19)
    #++(static prot ns x1a)
    #++(private ns x05)))

(defun assemble-function (name data)
  #+nil(format t "--assemble-function ~s :~%" name)
  (destructuring-bind (n nid argtypes return-type flags asm
                         &key activation-slots class-name class-static
                         anonymous trait trait-type function-deps class-deps
                         optional-args literals circularity-fixups )
      data
    (declare (ignore function-deps class-deps))
    ;(format t "literals = ~s~%" (reverse literals))
    ;(format t "circ = ~s~%" circularity-fixups)
    (loop for (value code) in (reverse literals)
       do (coalesce-literal value code))
    (loop for (value code) in circularity-fixups
       do (add-circularity-fixup value code))
    ;;(format t "--assemble-function ~s : ~s : ~s~%" name n nid)
    (let* ((traits (loop for (name index type) in activation-slots
                         ;;do (format t "trait = ~s ~s ~s ~%" name index type)
                         collect (make-instance
                                  'avm2-asm::trait-info
                                  'avm2-asm::name (avm2-asm::asm-intern-multiname name)
                                  'avm2-asm::trait-data
                                  (make-instance
                                   'avm2-asm::trait-data-slot/const
                                   'avm2-asm::kind 0
                                   'avm2-asm::slot-id index
                                   'avm2-asm::type-name type
                                   'avm2-asm::vindex 0 ;; no value
                                   'avm2-asm::vkind 0 ;; no value
                                   ))))
           (rest-p (or (logbitp 0 flags)
                       (logbitp 2 flags)))
           (mid (avm2-asm::avm2-method name nid argtypes return-type flags
                                       :option-params
                                       (mapcar 'intern-constant optional-args)
                                       :body (avm2-asm::assemble-method-body
                                              asm
                                              :traits traits
                                              :arg-count (+ 1
                                                            (if rest-p 1 0)
                                                            (length argtypes))))))
      (when trait
        (setf n (if (symbolp trait)
                    (avm2-asm::symbol-to-qname-list trait)
                    `(:qname "" ,trait))))
      (if class-name
          ;; member function
          (let ((class (find-swf-class class-name))
                (override-p nil))
            (assert class) ;; fixme: handle this better
            (when class
              (loop for super = (extends class) then (extends sc)
                 for sc = (find-swf-class super)
                 while (and super sc)
                 do (format t "check for inherited method ~s in class ~s, super=~s~% ~s~%" n class-name super (functions sc))
                 when (member n (functions sc) :test 'equal :key 'car)
                 do (setf override-p t)
                 (loop-finish))
              (when override-p (format t "===> got override~%" )))
            ;(find-swf-class 'flash:object)
            (macrolet ((add (n mid alist &optional flags)
                         `(progn
                            (let ((c (assoc ,n ,alist :test 'equal)))
                              (if c (rplacd c (list ,mid))
                                  (push (list ,n ,mid ,@(when flags
                                                              (list flags)))
                                        ,alist))))))
              (cond
                ((getf (flags class) :methods-as-properties)
                 ;; for some stuff like setf, we want functions as
                 ;; properties instead of actual methods, so we can use
                 ;; the class as a namespace without it showing up in the
                 ;; scope for functions in that namespace
                 ;; so add an anonymous function to be put into the slot later
                 #++(format t "assemble fun ~s / ~s for namespace ~s~% " name n class-name)
                 #++(format t "=~s~%" (list (list :qname "|setf|" (format nil "~s" trait)))
                         n mid)
                 (push (list (list :qname "|setf|" (format nil "~s" trait)) mid)
                       (function-names *compiler-context*))
                 (add n (list :qname "|setf|" (format nil "~s" trait))  (class-functions class)))

                (class-static
                 (add n mid (class-functions class)))
                (t (add n mid (functions class)
                        (list :override override-p))))))
          ;; normal function
          (cond
            ;; fixme: should these use trait instead of n ?
            ((and (not anonymous) trait (eq trait-type :function))
             (push (list n mid) (function-names *compiler-context*)))
            ((and trait (eq trait-type :slot))
             (push (list n 0) (script-slots *compiler-context*)))
            (t
             #++(format t "no trait for function ~s  =~%" name)))))))
;++
(defun assemble-class (name ns super properties constructor instance-functions class-properties class-functions flags implements)
  (let* ((constructor-mid
          (cond
            #++((consp constructor)
             (avm2-asm::avm2-method
              nil 0 ;; id name
              (loop for i in (first constructor)
                 collect 0) ;; constructor arg types
              0 0
              :body
              (avm2-asm::assemble-method-body
               (%compile-defun name (first constructor)
                               (second constructor) t
                               (or (third constructor) t)))))
            ((numberp constructor) constructor)
            (t (avm2-asm::intern-method-id constructor))))
         ;; fixme: probably should make this configurable at some point
         (class-init (avm2-asm::avm2-method nil 0 nil 0 0 ;; meta-class init
                                          :body
                                          (avm2-asm::assemble-method-body
                                           `((:get-local-0)
                                             (:push-scope)
                                             ,@ (when (getf flags :methods-as-properties)
                                                  (loop for (sn an) in class-functions
                                                     append `((:get-local-0)
                                                              (:get-lex ,an)
                                                              (:set-property ,sn))))
                                             (:return-void))
                                           :init-scope 0)))
         (junk (avm2-asm::avm2-ns-intern ns))
         (class (avm2-asm::avm2-class
                 (avm2-asm::asm-intern-multiname name)
                 (avm2-asm::asm-intern-multiname
                  (or (swf-name (find-swf-class super))
                      super))
                 ;;flags 1=sealed,2=final,4=interface, 8=protectedns?
                 flags ;; (:sealed :final :interface :protected-namespace)
                 (loop for i in implements
                    collect (avm2-asm::asm-intern-multiname
                             (or (swf-name (find-swf-class i))
                                 i)))
                 constructor-mid
                 (append
                  (loop for i in properties
                        collect
                        (make-instance
                         'avm2-asm::trait-info
                         'avm2-asm::name (avm2-asm::asm-intern-multiname i)
                         'avm2-asm::trait-data
                         (make-instance 'avm2-asm::trait-data-slot/const
                                        'avm2-asm::kind 0
                                        'avm2-asm::slot-id 0 ;; auto-assign
                                        'avm2-asm::type-name 0 ;; */t
                                        'avm2-asm::vindex 0 ;; no value
                                        'avm2-asm::vkind 0 ;; no value
                                        )))
                  (loop for (name index fflags) in instance-functions
                        collect
                        (make-instance
                         'avm2-asm::trait-info
                         'avm2-asm::name (avm2-asm::asm-intern-multiname name)
                         'avm2-asm::trait-data
                         (make-instance 'avm2-asm::trait-data-method/get/set
                                        'avm2-asm::slot-id 0 ;; none
                                        'avm2-asm::method index
                                        'avm2-asm::flags fflags))))
                 class-init
                 :protected-ns junk
                 :class-traits
                 (append
                  (loop for i in class-properties
                        collect
                        (make-instance
                         'avm2-asm::trait-info
                         'avm2-asm::name (avm2-asm::asm-intern-multiname i)
                         'avm2-asm::trait-data
                         (make-instance 'avm2-asm::trait-data-slot/const
                                        'avm2-asm::kind 0
                                        'avm2-asm::slot-id 0 ;; auto-assign
                                        'avm2-asm::type-name 0 ;; */t
                                        'avm2-asm::vindex 0 ;; no value
                                        'avm2-asm::vkind 0 ;; no value
                                        )))
                  (loop for (name index fflags) in class-functions
                     collect
                     (make-instance
                      'avm2-asm::trait-info
                      'avm2-asm::name (avm2-asm::asm-intern-multiname name)
                      'avm2-asm::trait-data
                      (if (getf flags :methods-as-properties)
                          (make-instance 'avm2-asm::trait-data-slot/const
                                         'avm2-asm::kind 0
                                         'avm2-asm::slot-id 0 ;; auto-assign
                                         'avm2-asm::type-name 0 ;; */t
                                         'avm2-asm::vindex 0 ;; no value
                                         'avm2-asm::vkind 0) ;; no value
                          (make-instance 'avm2-asm::trait-data-method/get/set
                                         'avm2-asm::slot-id 0 ;; none
                                         'avm2-asm::method index
                                         'avm2-asm::flags fflags)))))
                 ;; todo: class traits
                 ;; :class-traits nil
                 )))
    (format t "add ~s to compiler context~%" (list name class))
    (push (list name class) (class-names *compiler-context*))))
