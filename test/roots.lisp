;;; sample from old version, not fully converted yet...

(with-open-file (s "/tmp/roots.swf"
                   :direction :output
                              :element-type '(unsigned-byte 8)
                              :if-exists :supersede)
  (with-compilation-to-stream s ("frame1" `((0 "test-class")))
    (let*
        ((constr
          (swf-constructor "-constr-" ()
            (:main this)))

         (cinit (as3-method 0 nil 0 0 ;; meta-class init
                            :body
                            (assemble-method-body
                             `((:get-local-0)
                               (:push-scope)
                               (:return-void))
                             :init-scope 0)))

         (junk (as3-ns-intern "test-class"))
         (class (as3-class
                 (qname "" "test-class")
                 (qname "flash.display" "Sprite")
                 09 nil constr nil
                 cinit
                 :protected-ns junk )))

      (push (list "test-class" class) (class-names *compiler-context*))

      (swf-defmemfun random-range (a b)
        (+ a (floor (random (- b a)))))

      (swf-defmemfun radians (a)
        (/ (* a flash::math.PI) 180.0))

      (swf-defmemfun i255 (a)
        (flash::Math.max (flash::Math.min (floor (* a 256)) 255) 0))

      (swf-defmemfun rgb (r g b)
        (+ (* (i255 r) 65536) (* (i255 g) 256) (i255 b)))

      (swf-defmemfun :main (arg)
        (let ((foo (%asm (:new (qname "flash.text" "TextField") 0)))
              (canvas (%asm (:new (qname "flash.display" "Sprite") 0))))
          (%set-property foo :auto-size "left")
          (%set-property foo :text (+ "testing..." (%call-property (%array 1 2 3) :to-string)))
          (:add-child arg canvas)
          (:add-child arg foo)
          (%set-property this :canvas canvas)
          (frame :null)
          #+nil(:add-event-listener arg "enterFrame" (%get-lex :frame))
          (:add-event-listener canvas "click" (%get-lex frame))))

      (swf-defmacro with-fill (gfx (color alpha &key line-style) &body body)
        `(progn
           ,@(when line-style
                   `((:line-style ,gfx ,@line-style)))
           (:begin-fill ,gfx ,color ,alpha)
           ,@body
           (:end-fill ,gfx)))

      (swf-defmemfun frame (evt)
        (let* ((canvas (%get-property this :canvas))
               (gfx (:graphics canvas))
               (matrix (%asm (:new (qname "flash.geom" "Matrix") 0))))

          (%set-property canvas :opaque-background #x0d0f00)
          (:clear gfx)
          (with-fill gfx (#x202600  0.5)
            (:draw-rect gfx 0 0 400 300 ))
          (:create-gradient-box matrix
                          400 300 0 0 0)
          (:begin-gradient-fill gfx "radial"
                          (%array #x202600 #x0d0f00) ;; colors
                          (%array 1 1) ;; alpha
                          (%array 0 255) ;; ratios
                          matrix)
          (:draw-rect gfx 0 0 400 300 )
          (:end-fill gfx)
          (root canvas 200 150 (random 360) 7 1.0 0.005 )))

      (swf-defmemfun root (canvas x y angle depth alpha decay)
        (%set-local alpha (%to-double alpha))
        (%set-local x (%to-double x))
        (%set-local y (%to-double y))
        (let* ((s (* depth 0.5))
               (w (* s 6.0))
               (line-size (* s 0.5))
               (gfx (:graphics canvas )))
          (dotimes (i (%to-integer (* depth (random-range 10 20))))
            (let* ((v (/ depth 5.0))
                   (color (rgb  (- 0.8 (* v 0.25))
                                 0.8
                                 (- 0.8 v))))
              (%set-local alpha (flash::Math.max 0.0 (- alpha (* i decay))))

              ;; stop if alpha gets below 1/256 or so
              (when (> alpha 0.004)
                (%set-local angle (+ angle (random-range -60 60)))
                (let ((dx (+ x (* (cos (radians angle)) w)))
                      (dy (+ y (* (sin (radians angle)) w))))

                  ;; drop shadow
                  (with-fill gfx (0 (* alpha 0.6) :line-style (:nan 0 alpha))
                             (:draw-circle gfx (+ x s 1) (1- (+ y s)) (/ w 3)))

                  ;; line segment to next position:
                  (with-fill gfx (color (* alpha 0.6)
                                        :line-style (line-size color alpha))
                             (:move-to gfx x y)
                             (:line-to gfx dx dy))

                  ;; filled circle
                  (with-fill gfx (color (* alpha 0.5)
                                        :line-style ((* 0.5 line-size)
                                                     color alpha))
                             (:draw-circle gfx x y (/ w 4)))

                  (when (and (> depth 0) (> (random 1.0) 0.85))
                    (root canvas x y (+ angle (random-range -60 60))
                           (1- depth) alpha decay))
                  (%set-local x (%to-double dx))
                  (%set-local y (%to-double dy))))))

          (when (and (> depth 0) (> (random 1.0) 0.7))
            (root canvas x y angle (1- depth) alpha decay)))))))