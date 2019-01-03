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

(require "db.ss" "utils.ss")
(provide (all-defined-out))

(require (planet jaymccarthy/sqlite:5:1/sqlite))

(define max-pop-size 128)
(define min-tests 5)
(define pop-top 64)

;;(define max-pop-size 28)
;;(define min-tests 2)
;;(define pop-top 14)

(define (pop-least-tested db population replicate)
  (let* ((gen (get-state db population replicate "generation"))
         (s (select
             db (string-append "select e.tests from egg as e where "
                               "e.population = ? and "
                               "e.replicate = ? and "
                               "e.generation = ? "
                               "order by e.tests limit 1")
             population replicate gen)))
    (if (null? s) 0 (vector-ref (cadr s) 0))))

(define (pop-size db population replicate)
  (let* ((gen (get-state db population replicate "generation"))
         (s (select
             db (string-append "select count(*) from egg as e where "
                               "e.population = ? and "
                               "e.replicate = ? and "
                               "e.generation = ?")
             population replicate gen)))
    (if (null? s) 0 (vector-ref (cadr s) 0))))

(define (pop-next-size db population replicate)
  (let* ((gen (+ (get-state db population replicate "generation") 1))
         (s (select
             db (string-append "select count(*) from egg as e where "
                               "e.population = ? and "
                               "e.replicate = ? and "
                               "e.generation = ? ")
             population replicate gen)))
    (if (null? s) 0 (vector-ref (cadr s) 0))))

;; copy the top
(define (pop-copy-top db population replicate)
  (let ((s (select
            db (string-append
                "select e.player_id, e.id, e.image, e.x_pos, e.y_pos, e.genotype from egg as e where "
                "e.population = ? and "
                "e.replicate = ? and "
                "e.generation = ? "
                "order by (e.fitness / e.tests) desc limit ?")
            population replicate
            (get-state db population replicate "generation") pop-top))
        (timestamp (timestamp-now)))
    (exec/ignore db "begin transaction")
    (when (not (null? s))
          (for-each
           (lambda (i)
             (insert-egg
              db population replicate timestamp
              (vector-ref i 0) ;; player id
              0 ;; fitness
              0 ;; tests
              (+ (get-state db population replicate "generation") 1)
              (vector-ref i 1) ;; parent id
              (vector-ref i 2) ;; image
              (inexact->exact (vector-ref i 3)) ;; x-pos
              (inexact->exact (vector-ref i 4)) ;; y-pos
              (vector-ref i 5))) ;; genotype
           (cdr s)))
    (exec/ignore db "end transaction")))

(define (control-fitness db player-id fitness)
  (let ((played/average (get-player-played/average db player-id)))
    (cond
     ;; not in database or played before - pass through
     ((or (null? played/average)
          (eq? (car (car played/average)) 0))
      ;;(msg "fitness control pass-through")
      fitness)
     (else
      (let* ((info (car played/average))
             (times-played (car info))
             (acc-average (cadr info))
             (average-time (/ acc-average times-played)))
        (msg "fitness control: average-time" average-time)
        fitness)))))

(define clock 0)

(define (pop-add db population replicate egg-phase egg-id player-id fitness parent image x-pos y-pos genotype)
  (let ((phase (get-state db population replicate "phase"))
        (timestamp (timestamp-now))
        (fitness (control-fitness db player-id fitness)))

    ;; tick the update here...
    (set! clock (+ clock 1))
    (when (zero? (modulo clock 10)) (update-global-info db))

    (cond
     ((not (equal? phase egg-phase))
      (msg "rejecting egg - phase has changed"))

     ((equal? phase "init")
      ;; add to the first generation
      (insert-egg
       db population replicate timestamp player-id
       fitness 1 0 0 image x-pos y-pos genotype)
      ;; check if we are finished
      (when (>= (pop-size db population replicate) max-pop-size)
            (set-state db population replicate "phase" "test")))

     ((equal? phase "test")
      (update-egg db population replicate egg-id fitness)
      (when (>= (pop-least-tested db population replicate) min-tests)
            (pop-copy-top db population replicate)
            (set-state db population replicate "phase" "fill")))

     ((equal? phase "fill")
      (msg "filling:" population " " replicate " gen: "
	   (get-state db population replicate "generation"))
      (insert-egg
       db population replicate timestamp player-id
       fitness 1 (+ (get-state db population replicate "generation") 1)
       parent image x-pos y-pos genotype)

      (when (>= (pop-next-size db population replicate) max-pop-size)
            (set-state db population replicate "generation"
                       (+ (get-state db population replicate "generation") 1))
            (set-state db population replicate "phase" "test")))))
  '("ok"))

;; return count number of eggs from eggs with fitness higher than
;; thresh-fitness in the population and replicate specified
(define (inner-pop-sample db population replicate count)
  (let ((phase (get-state db population replicate "phase"))
        (generation (get-state db population replicate "generation")))
    (cond
     ;; return nothing when initialising
     ((equal? phase "init") '())

     ;; get the least tested individuals
     ((equal? phase "test")
      (let ((s (select
                db (string-append
                    "select e.genotype, e.fitness, e.generation, e.id, e.generation from egg as e where "
                    "e.population = ? and "
                    "e.replicate = ? and "
                    "e.generation = ? "
                    "order by e.tests limit ?")
                population replicate generation count)))
        (if (null? s)
            '()
            (map
             (lambda (i)
               (list
                (vector-ref i 0)
                (vector-ref i 1)
                (vector-ref i 2)
                (vector-ref i 3)
                (vector-ref i 4)))
             (cdr s)))))

     ;; use the read head to get the next individuals from the
     ;; top fitness of this populaton
     ((equal? phase "fill")
      (let ((s (select
                db (string-append
                    "select e.genotype, e.fitness / e.tests, e.generation, e.id, e.generation from egg as e where "
                    "e.population = ? and "
                    "e.replicate = ? and "
                    "e.generation = ? "
                    "order by (e.fitness / e.tests) desc limit ? offset ?")
                population replicate generation count
                (get-state db population replicate "read_head"))))

        ;; rotate the read head
        (set-state db population replicate "read_head"
                   (+ (get-state db population replicate "read_head")
                    count))
        (when (> (get-state db population replicate "read_head") pop-top)
              (set-state db population replicate "read_head" 0))

        (if (null? s)
            '()
            (map
             (lambda (i)
               (list
                (vector-ref i 0)
                (vector-ref i 1)
                (vector-ref i 2)
                (vector-ref i 3)
                (vector-ref i 4)))
             (cdr s))))))))

(define (pop-sample-egghunt db population replicate count)
  (let ((replicate (if (check-replicate db replicate) replicate 0)))
    (check/init-state db population replicate)
    (list
     (get-state db population replicate "phase")
     (inner-pop-sample db population replicate count))))


(define (pop-sample db population replicate count)
  (check/init-state db population replicate)
  (list
   (get-state db population replicate "phase")
   (inner-pop-sample db population replicate count)))

(define (pop-stats db population)
  (let ((s (select
            db (string-append
                "select e.generation, avg(e.fitness/e.tests) "
                "from egg as e where e.population = ? group by generation")
            population)))
    (if (null? s)
        '()
        (map
         (lambda (i)
           (list
            (vector-ref i 0)
            (vector-ref i 1)))
         (cdr s)))))


(define (check-replicate/pop db population replicate)
  (let ((s (select db "select phase from state where population = ? and replicate = ?" population replicate)))
    (if (null? s)
        #f (not (equal? (vector-ref (cadr s) 0) "init")))))

(define (check-replicate db replicate)
  (and
   (check-replicate/pop db "slow" replicate)
   (check-replicate/pop db "medium" replicate)
   (check-replicate/pop db "fast" replicate)))

;; top n eggs
(define (top-eggs db population replicate count)
  (let ((replicate (if (check-replicate db replicate) replicate 0)))
    (let ((s (select
              db (string-append
                  "select e.genotype, (e.fitness / e.tests), e.id, e.replicate, e.generation from egg as e "
                  "where e.population = ? and e.replicate = ? "
                  "and e.generation = ? "
                  "order by (e.fitness / e.tests) desc limit ?")
              population replicate (get-state db population replicate "generation") count)))
      (if (null? s)
          '()
          (map
           (lambda (i)
             (list (vector-ref i 0)
                   (vector-ref i 1)
                   (vector-ref i 2)
                 (vector-ref i 3)
                 (vector-ref i 4)))
           (cdr s))))))



;(define (sample-eggs-from-top db population replicate count top)
;  (let ((f (get-fitness-thresh db population replicate top)))
;    (if (null? f)
;        (sample-egg db population replicate count 0)
;        (sample-egg db population replicate count (inexact->exact (round (car f)))))))


;; return a bunch of (id genome) lists for inheritence viz


(define (pop-all db population replicate generation)
  (let ((s (select
            db (string-append
                "select e.id, e.genotype, e.parent, e.fitness/e.tests, e.tests from egg as e where "
                "e.population = ? and "
                "e.replicate = ? and "
                "e.generation = ? order by (e.fitness/e.tests) desc")
            population replicate generation)))
    (if (null? s)
        '()
        (map
         (lambda (i)
           (list
            (vector-ref i 0)
            (vector-ref i 1)
            (vector-ref i 2)
            (vector-ref i 3)
            (vector-ref i 4)
            ))
         (cdr s)))))

(define (pop-every db id)
  (let ((s (select
            db (string-append
                ;;"select e.id, e.genotype, e.parent, e.fitness/e.tests, e.tests from egg as e where e.id=?;"
		"select e.id, e.genotype, e.parent, e.fitness/e.tests, e.tests from egg as e where id not in (select pattern_id from render) order by random() limit 1;")
            ;;id
	    )))
    (if (null? s)
        '()
        (map
         (lambda (i)
           (list
            (vector-ref i 0)
            (vector-ref i 1)
            (vector-ref i 2)
            (vector-ref i 3)
            (vector-ref i 4)
            ))
         (cdr s)))))

(define (get-individual db id)
  (let ((s (select db "select e.parent, e.genotype, e.generation, (e.fitness/e.tests) from egg as e where e.id = ? " id)))
    (if (null? s)
        '()
        (map
         (lambda (i)
           (list (vector-ref i 0) (vector-ref i 1) (vector-ref i 2) (vector-ref i 3)))
         (cdr s)))))

(define (family-tree db id)
  (get-family-tree db (car (get-individual db id))))

(define (get-family-tree db egg)
  (let ((p (get-parent db egg)))
    (if (null? p) (list (list egg '()))
        (cons (list egg (get-children db egg))
              (get-family-tree db (car p))))))

(define (get-parent db egg)
  (let ((s (select db "select e.parent, e.genotype, e.generation, (e.fitness/e.tests) from egg as e where e.id = ? " (car egg))))
    (if (null? s)
        '()
        (map
         (lambda (i)
           (list (vector-ref i 0) (vector-ref i 1) (vector-ref i 2) (vector-ref i 3)))
         (cdr s)))))

(define (get-children db egg)
  (let ((s (select db "select e.id, e.genotype, e.generation,  (e.fitness/e.tests) from egg as e where e.parent = ? " (car egg))))
    (if (null? s)
        '()
        (map
         (lambda (i)
           (list (vector-ref i 0) (vector-ref i 1) (vector-ref i 2) (vector-ref i 3)))
         (cdr s)))))

;;;;;

(define (get-genzero db)
  (let ((s (select db "select e.id from egg as e where e.generation = 0")))
    (if (null? s)
        '()
        (map
         (lambda (i)
           (vector-ref i 0))
         (cdr s)))))


(define (get-single db id)
  (let ((s (select db "select e.id, e.parent, e.genotype, e.generation, (e.fitness/e.tests), population, replicate, x_pos, y_pos, tests, image from egg as e where e.id = ? " id)))
    (if (null? s)
        '()
        (car
         (map
          (lambda (i)
            (list (vector-ref i 0) ; id
                  (vector-ref i 1) ; parent
                  (vector-ref i 2) ; geno
                  (vector-ref i 3) ; generation
                  (vector-ref i 4) ; fitness
                  (vector-ref i 5) ; pop
                  (vector-ref i 6) ; rep
                  (vector-ref i 7) ; x
                  (vector-ref i 8) ; y
                  (vector-ref i 9) ; tests
                  (vector-ref i 10) ; image
                  ))
          (cdr s))))))


(define (get-dindividual db id)
  (let ((s (select db "select e.id, e.parent, e.genotype, e.generation, (e.fitness/e.tests) from egg as e where e.id = ? " id)))
    (if (null? s)
        '()
        (car
         (map
          (lambda (i)
            (list (vector-ref i 0) (vector-ref i 1) (vector-ref i 2) (vector-ref i 3)))
          (cdr s))))))

(define (get-decendents db egg-id)
  (let ((s (select
            db  "select e.id, e.parent, e.genotype, e.generation, (e.fitness/e.tests) from egg as e where e.parent = ? " egg-id)))
    (msg "gd" egg-id)
    (if (null? s)
        '()
        (map
         (lambda (i)
           (list
            (list (vector-ref i 0) (vector-ref i 1) (vector-ref i 2)  (vector-ref i 3))
            (get-decendents db (vector-ref i 0))))
         (cdr s)))))

(define (count-decendents db egg-id)
  (let ((s (select
            db  "select e.id, e.parent, e.genotype, e.generation, (e.fitness/e.tests) from egg as e where e.parent = ? " egg-id)))
    (if (null? s)
        1
        (foldl
         (lambda (i r)
           (+ r (count-decendents db (vector-ref i 0))))
         1
         (cdr s)))))


(define (calc-player-average db)
  (let ((s (select db "select avg(acc_average/games_played) from player where games_played>0")))
    (if (null? s)
        '()
        (car
         (map
          (lambda (i)
            (list (vector-ref i 0)))
          (cdr s))))))

(define (update-global-info db)
  (let ((player-average (calc-player-average db)))
    (when (not (null? player-average))
          (let ((player-average (car player-average)))
            ;;(msg "global player average now: " player-average)
            (exec/ignore db "insert or replace into global_info (id, player_average) values (1, ?)"
                         player-average)))))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; game stuff

(define (init-player db)
  (list
   "player-id"
   (insert-player
    db (timestamp-now) "" 0 0)))

(define (player db player-id name played-before age-range)
  (update-player db player-id name played-before age-range)
  '("ok"))

(define (test-add1 db population replicate egg-id player-id parent image x-pos y-pos genome)
  (pop-add db population replicate egg-id player-id (if (equal? genome "good") (+ (random 100) 20) (random 100))
           parent image x-pos y-pos genome))

(define (test-add2 db population replicate egg-id player-id parent image x-pos y-pos genome)
  (pop-add db population replicate egg-id player-id (if (equal? genome "good2") (+ (random 100) 20) (random 100))
           parent image x-pos y-pos genome))

(define (stats db population replicate)
  (msg "popsize: " (pop-size db population replicate)
       "popleast: " (pop-least-tested db population replicate)
       "generation: " (get-state db population replicate "generation")
       "popnextsize: " (pop-next-size db population replicate))
  (msg (pop-stats db "slow"))
  (msg (pop-stats db "fast")))

(define (pop-unit-tests)
  (define (emulate db pop rep add)
    (let ((samples (pop-sample db pop rep 5)))
      ;;(msg "-----------------")
      (msg samples)
      (cond
       ((equal? (car samples) "init")
        ;; add some new ones
        (for ((i (in-range 0 10)))
             (if (< (random 50) 25)
                 (pop-add db pop rep -1 0 (random 100) 0 "" 0 0 (if (equal? pop "CF") "bad" "bad2"))
                 (pop-add db pop rep -1 0 (random 100) 0 "" 0 0 (if (equal? pop "CF") "good" "good2")))))
       ((equal? (car samples) "test")
        (for-each
         (lambda (egg)
           (add db pop rep (list-ref egg 3) 0 0 "" 0 0 (list-ref egg 0)))
         (cadr samples)))
       ((equal? (car samples) "fill")
        (for-each
         (lambda (egg)
           ;; mutate
           (add db pop rep 0 0 (list-ref egg 3) "" 0 0 (list-ref egg 0)))
         (cadr samples))))))



  ;; db
  (msg "testing db")
  (define db (open-db "unit-test.db"))

  (for ((i (in-range 0 100000)))
       (msg "----------- 1 ----------------------")
       (emulate db "CF" 0 test-add1)
       (emulate db "CF" 0 test-add1)
       (stats db "CF" 0)
       (msg "----------- 2 ----------------------")
       (emulate db "MV" 23 test-add2)
       (stats db "MV" 23)
       )

;  (let ((id (cadr (player db "pop1" 0 "dave" 100 #t 3))))
;    (for ((i (in-range 0 10)))
;         (pop-add db "pop1" 0 id (random 1000) 200 1 0 "img" (string-append "(foo" (number->string i) ")")))
;
;    (msg (sample-eggs-from-top db "pop1" 0 2 3))
;    (msg (top-eggs db "pop1" 0 10))
;    (msg (get-stats db "pop1" 0 10)) )

    )

;(pop-unit-tests)
