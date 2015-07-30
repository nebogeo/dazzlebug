#!/usr//bin/env mzscheme
#lang scheme/base
;; Naked on Pluto Copyright (C) 2010 Aymeric Mansoux, Marloes de Valk, Dave Griffiths
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.
;;
;; You should have received a copy of the GNU Affero General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

(require scheme/system
         scheme/foreign
         scheme/cmdline
         mzlib/string
         web-server/servlet
         web-server/servlet-env
         web-server/http/response-structs
         "server/filter-string.ss"
         "server/request.ss"
         "server/logger.ss"
         "server/json.ss"
         "server/utils.ss"
         "server/db.ss"
         "server/txt.ss"
         "server/pop.ss")

; a utility to change the process owner,
; assuming mzscheme is called by root.
;;(unsafe!)
;;(define setuid (get-ffi-obj 'setuid #f (_fun _int -> _int)))

(define db-name "seeme.db")
(define db (open-db db-name))
(open-log "log.txt")

;; (dbg (get-family-tree db (list 164 #f)))

(define sema (make-semaphore 1))

(define (syncro-old fn)
  (msg "s-start")
  (semaphore-wait sema)
  (let ((r (fn)))
    (msg "s-end")
    (semaphore-post sema)
    r))

(define (syncro fn)
  (fn))

(define registered-requests
  (list

   (register
    (req 'ping '())
    (lambda ()
      (pluto-response (scheme->json '("hello")))))

   (register
    (req 'add '(phase population replicate pattern-id player-id fitness parent image x-pos y-pos genotype))
    (lambda (phase population replicate pattern-id player-id fitness parent image x-pos y-pos genotype)
    (syncro
       (lambda ()
      (pluto-response
       (scheme->json
        (pop-add
         db
         population
         (string->number replicate)
         phase
         (string->number pattern-id)
         (string->number player-id)
         (min (string->number fitness) 10000)
         (string->number parent)
         image
         (string->number x-pos)
         (string->number y-pos)
         ;; store in escaped JSON format so we don't ever need to eval them
         (escape-quotes genotype))))))))

   (register
    (req 'add-click '(player_id pattern_id mouse_x mouse_y target_x target_y target_dir_x target_dir_y success))
    (lambda (player_id pattern_id mouse_x mouse_y target_x target_y target_dir_x target_dir_y success)
      (syncro
       (lambda ()
         (pluto-response
          (scheme->json
           (insert-performance
            db
            (string->number player_id)
            (string->number pattern_id)
            (string->number mouse_x)
            (string->number mouse_y)
            (string->number target_x)
            (string->number target_y)
            (string->number target_dir_x)
            (string->number target_dir_y)
            (string->number success))))))))

   (register
    (req 'sample '(player-id replicate count))
    (lambda (player-id replicate count)
      (let ((samples (map
                      (lambda (population)
                        (msg "-----------------------------")
                        (msg population)
                        (pop-sample
                         db population
                         (string->number replicate)
                         (string->number count)))
                      (list "fast" "slow" "medium"))))
        (pluto-response
         (scheme->json
          (list
           ;; init the player if needed, at the same time
           (if (eq? (string->number player-id) 0)
               (init-player db)
               (list "player-id" (string->number player-id)))
           samples))))))



   (register
    (req 'get-all '(population replicate generation))
    (lambda (population replicate generation)
      (msg "get-all:" population replicate generation)
      (pluto-response
       (scheme->json
        (pop-all db population
                 (string->number replicate)
                 (string->number generation))))))

   (register
    (req 'get-decendents '(egg-id))
    (lambda (egg-id)
      (pluto-response
       (scheme->json
        (list
         (get-dindividual db (string->number egg-id))
         (get-decendents db (string->number egg-id))))
       )))

   (register
    (req 'get-single '(egg-id))
    (lambda (egg-id)
      (pluto-response
       (scheme->json
        (get-single db (string->number egg-id)))
       )))



;   (pluto-response
;-       (string-append
;-        (scheme->txt
;-         (string-append
;-          "(list "
;-          (apply
;-           string-append
;-           (sample-eggs-from-top
;-            db
;-            population
;-            (string->number replicate)
;-            (string->number count)
;-            (string->number top)))
;-          ")"))))))


   (register
    (req 'top-patterns '(replicate count))
    (lambda (replicate count)
    (syncro
       (lambda ()
      (pluto-response
       (scheme->json
        (list
         (top-eggs db "fast" replicate (string->number count))
         (top-eggs db "medium" replicate (string->number count))
         (top-eggs db "slow" replicate (string->number count))
         )))))))

   (register
    (req 'family-tree '(id))
    (lambda (id)
    (syncro
       (lambda ()
      (pluto-response
       (scheme->json
        (family-tree db (string->number id))))))))

   (register
    (req 'get-stats '())
    (lambda ()
    (syncro
       (lambda ()
      (pluto-response
       (scheme->json
        (list
         (pop-stats db "slow")
         (pop-stats db "medium")
         (pop-stats db "fast"))))))))


   (register
    (req 'init-player '())
    (lambda ()
    (syncro
       (lambda ()
      (pluto-response
       (scheme->json
        (init-player db)))))))

   (register
    (req 'player '(player-id name played-before age-range))
    (lambda (player-id name played-before age-range)
    (syncro
       (lambda ()
      (pluto-response
       (scheme->json
        (player
         db
         (string->number player-id)
         name
         played-before
         (string->number age-range))))))))

   (register
    (req 'add-score '(player-id name score replicate))
    (lambda (player-id name score replicate)
      (syncro
       (lambda ()
         (insert-score
          db
          (string->number player-id)
          name
          (string->number score)
          ""
          (string->number replicate)
          (get-state db "slow" replicate "generation"))
         (pluto-response
          (scheme->json '("ok")))))))

   (register
    (req 'hiscores '(count))
    (lambda (count)
    (syncro
       (lambda ()
      (pluto-response
       (scheme->json
        (list
         (hiscores db (string->number count))
        )))))))

   (register
    (req 'addegghunt '(background challenger message egg1 x1 y1 egg2 x2 y2 egg3 x3 y3 egg4 x4 y4 egg5 x5 y5))
    (lambda (background challenger message egg1 x1 y1 egg2 x2 y2 egg3 x3 y3 egg4 x4 y4 egg5 x5 y5)
    (syncro
       (lambda ()
      (let ((id (insert-egghunt db background challenger message 0)))
        (insert-egghunt-egg db id egg1 x1 y1)
        (insert-egghunt-egg db id egg2 x2 y2)
        (insert-egghunt-egg db id egg3 x3 y3)
        (insert-egghunt-egg db id egg4 x4 y4)
        (insert-egghunt-egg db id egg5 x5 y5)
        (pluto-response (scheme->json (list "id" id))))))))

   (register
    (req 'getegghunt '(id))
    (lambda (egghunt-id)
    (syncro
       (lambda ()
      (pluto-response
       (scheme->json
        (list
         (get-egghunt db (string->number egghunt-id))
         (get-egghunt-eggs db (string->number egghunt-id))
       )))))))))

(define (start request)
  (let ((values (url-query (request-uri request))))
    ;(msg values)
    (if (not (null? values))   ; do we have some parameters?
        (let ((name (assq 'fn values)))
          (if name           ; is this a well formed request?
              (request-dispatch
               registered-requests
               (req (string->symbol (cdr name))
                    (filter
                     (lambda (v)
                       (not (eq? (car v) 'fn)))
                     values)))
              (pluto-response (dbg "bad formed request thing"))))
        (pluto-response (dbg "malformed thingy")))))

(printf "server is running...~n")

; Here we become the user 'nobody'.
; This is a security rule that *only works* if nobody owns no other processes
; than mzscheme. Otherwise better create another dedicated unprivileged user.
; Note: 'nobody' must own the state directory and its files.

;(setuid 65534)

;;

(serve/servlet
 start
 ;; port number is read from command line as argument
 ;; ie: ./server.scm 8080
; #:listen-ip "192.168.2.1"
 #:listen-ip "127.0.0.1"
 #:port (string->number (command-line #:args (port) port))
 #:command-line? #t
 #:servlet-path "/egglab"
 #:server-root-path
 (build-path "client"))
