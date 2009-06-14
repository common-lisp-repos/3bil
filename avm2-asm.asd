
(defsystem :avm2-asm
           :depends-on ("ieee-floats")
           :components ((:module
                         "asm"
                         :serial t
                         :components
                         ((:file "package")
                          (:file "peephole")
                          (:file "context")
                          (:file "asm")
                          (:file "opcodes")
                          ;;(:file "library-packages")
                          ;;(:file "player-classes")
                          ;;(:file "context")
                          ;;(:file "opcodes2")
                          ;;(:file "misc")
                          ;;(:file "write")
                          ;;(:file "compiler-context")
                          ;;(:file "player-class-decl")
                          ;;(:file "compile")
                          )))
           :serial t)
