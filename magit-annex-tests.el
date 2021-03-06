;;; magit-annex-tests.el --- Tests for Magit-annex

;; Copyright (C) 2014-2018 Kyle Meyer <kyle@kyleam.com>
;;
;; License: GPLv3

;;; Code:

(require 'cl)
(require 'dash)
(require 'ert)

(require 'magit-annex)

;;; Utilities

;; Modified from Magit's magit-with-test-directory.
(defmacro magit-annex-with-test-directory (&rest body)
  (declare (indent 0) (debug t))
  (let ((dir (make-symbol "dir")))
    `(let ((,dir (file-name-as-directory (make-temp-file "magit-annex-" t)))
           (process-environment process-environment))
       (push "GIT_AUTHOR_NAME=A U Thor" process-environment)
       (push "GIT_AUTHOR_EMAIL=a.u.thor@example.com" process-environment)
       (condition-case err
           (cl-letf (((symbol-function #'message) (lambda (&rest _))))
             (let ((default-directory ,dir))
               ,@body))
         (error (message "Keeping test directory:\n  %s" ,dir)
                (signal (car err) (cdr err))))
       (delete-directory ,dir t))))

(defmacro magit-annex-with-test-repo (&rest body)
  (declare (indent 0) (debug t))
  `(magit-annex-with-test-directory
     (magit-call-git "init" ".")
     (magit-call-git "annex" "init" "test-repo")
     (unwind-protect
         (progn ,@body)
       (call-process "chmod" nil nil nil "-R" "777" "."))))

(defmacro magit-annex-with-test-repo-pair (&rest body)
  (declare (indent 0) (debug t))
  `(let ((repo1 (file-name-as-directory (make-temp-file "magit-annex-" t)))
         (repo2 (file-name-as-directory (make-temp-file "magit-annex-" t)))
         (process-environment process-environment))
     (push "GIT_AUTHOR_NAME=A U Thor" process-environment)
     (push "GIT_AUTHOR_EMAIL=a.u.thor@example.com" process-environment)
     (condition-case err
         (cl-letf (((symbol-function #'message) (lambda (&rest _))))
           (let ((default-directory repo1))
             (magit-call-git "init" ".")
             (magit-call-git "annex" "init" "repo1")
             (magit-annex-tests-modify-file "file")
             (magit-stage-file "file")
             (magit-call-git "commit" "-m" "normal commit")
             (magit-call-git "remote" "add" "repo2" repo2))
           (let ((default-directory repo2))
             (magit-call-git "clone" "-o" "repo1" repo1 ".")
             (magit-call-git "annex" "init" "repo2"))
           (let ((default-directory repo1))
             ,@body))
       (error (message "Keeping test directories:\n  %s\n%s" repo1 repo2)
              (signal (car err) (cdr err))))
     (call-process "chmod" nil nil nil "-R" "777" repo1)
     (call-process "chmod" nil nil nil "-R" "777" repo2)
     (delete-directory repo1 t)
     (delete-directory repo2 t)))

(defmacro magit-annex-tests-with-temp-bare-repo (&rest body)
  (declare (indent 0) (debug t))
  `(magit-annex-with-test-directory
     (magit-call-git "init" "-bare" ".")
     ,@body))

(defmacro magit-annex-tests-with-temp-clone (url &rest body)
  (declare (indent 1) (debug t))
  (let ((repo (gensym)))
    `(let ((,repo ,(or url 'default-directory)))
       (magit-annex-with-test-directory
         (magit-call-git "clone" ,repo ".")
         (magit-call-git "annex" "init" "test-repo")
         ;; Make a normal commit and push.
         (magit-annex-tests-modify-file "file")
         (magit-stage-file "file")
         (magit-call-git "commit" "-m" "normal commit")
         (magit-call-git "push")
         (magit-call-git "push" "-u" "origin" "git-annex")
         (unwind-protect
             (progn ,@body)
           (call-process "chmod" nil nil nil "-R" "777" "."))))))

(defun magit-annex-tests-wait ()
  (while (and magit-this-process
              (eq (process-status magit-this-process) 'run))
    (sleep-for 0.005)))

(defun magit-annex-tests-modify-file (filename)
  (with-temp-file (expand-file-name filename)
    (insert (symbol-name (gensym "content")))))

(defun magit-annex-tests-should-have-section (type info)
  (magit-status default-directory)
  (message (buffer-string))
  (should (--first (equal (magit-section-value it) info)
                   (magit-section-children
                    (magit-get-section `((,type) (status)))))))


;;; Annexing

(ert-deftest magit-annex-add-file-to-annex ()
  (magit-annex-with-test-repo
    (magit-annex-tests-modify-file "file")
    (should (not (file-symlink-p "file")))
    (magit-annex-add "file")
    (should (file-symlink-p "file"))
    (magit-annex-tests-should-have-section 'staged "file")))

(ert-deftest magit-annex-add-all-files-to-annex ()
  (magit-annex-with-test-repo
    (magit-annex-tests-modify-file "file1")
    (magit-annex-tests-modify-file "file2")
    (should (not (file-symlink-p "file1")))
    (let ((magit-annex-add-all-confirm nil))
      (magit-annex-add-all))
    (should (file-symlink-p "file1"))
    (should (file-symlink-p "file2"))
    (magit-annex-tests-should-have-section 'staged "file1")
    (magit-annex-tests-should-have-section 'staged "file2")))


;;; Updating

(ert-deftest magit-annex-sync ()
  (magit-annex-with-test-repo-pair
    (let ((default-directory repo2))
      (magit-annex-tests-modify-file "annex-file")
      (magit-annex-add "annex-file")
      (magit-call-git "commit" "-m" "annex commit")
      (magit-annex-sync)
      (magit-annex-tests-wait)
      (should (magit-git-lines "diff" "repo1/master"))
      (should-not (magit-git-lines "diff" "synced/master"))
      (should (magit-annex-present-files)))
    (let ((default-directory repo1))
      (magit-annex-merge)
      (magit-annex-tests-wait)
      (should-not (magit-annex-present-files)))))

(ert-deftest magit-annex-sync-content ()
  (magit-annex-with-test-repo-pair
    (let ((default-directory repo2))
      (magit-annex-tests-modify-file "annex-file")
      (magit-annex-add "annex-file")
      (magit-call-git "commit" "-m" "annex commit")
      (magit-annex-sync '("--content"))
      (magit-annex-tests-wait)
      (should (magit-git-lines "diff" "repo1/master"))
      (should-not (magit-git-lines "diff" "synced/master"))
      (should (magit-annex-present-files)))
    (let ((default-directory repo1))
      (magit-annex-merge)
      (magit-annex-tests-wait)
      (should (magit-annex-present-files)))))


;;; Managing content

(ert-deftest magit-annex-get-all-auto ()
  (magit-annex-with-test-repo-pair
    (let ((default-directory repo2))
      (magit-annex-tests-modify-file "annex-file")
      (magit-annex-add "annex-file")
      (magit-call-git "commit" "-m" "annex commit")
      (magit-annex-sync)
      (magit-annex-tests-wait))
    (let ((default-directory repo1))
      (magit-annex-merge)
      (magit-annex-tests-wait)
      (magit-annex-get-all-auto)
      (magit-annex-tests-wait)
      ;; Shouldn't be present because of --auto flag.
      (should-not (magit-annex-present-files)))))

(ert-deftest magit-annex-get-files ()
  (magit-annex-with-test-repo-pair
    (let ((default-directory repo2))
      (magit-annex-tests-modify-file "annex-file")
      (magit-annex-add "annex-file")
      (magit-call-git "commit" "-m" "annex commit")
      (magit-annex-sync)
      (magit-annex-tests-wait))
    (let ((default-directory repo1))
      (magit-annex-merge)
      (magit-annex-tests-wait)
      (should-not (magit-annex-present-files))
      (magit-annex-get-files '("annex-file"))
      (magit-annex-tests-wait)
      (should (equal (magit-annex-present-files)
                     '("annex-file"))))))

(ert-deftest magit-annex-drop-files ()
  (magit-annex-with-test-repo-pair
    (let ((default-directory repo2))
      (magit-annex-tests-modify-file "annex-file")
      (magit-annex-add "annex-file")
      (magit-call-git "commit" "-m" "annex commit")
      (magit-annex-sync)
      (magit-annex-tests-wait)
      (magit-annex-drop-files '("annex-file") '("--force"))
      (magit-annex-tests-wait)
      (should-not (magit-annex-present-files)))))

(ert-deftest magit-annex-move-files ()
  (magit-annex-with-test-repo-pair
    (let ((default-directory repo2))
      (magit-annex-tests-modify-file "annex-file")
      (magit-annex-add "annex-file")
      (magit-call-git "commit" "-m" "annex commit")
      (magit-annex-sync)
      (magit-annex-tests-wait)
      (magit-annex-move-files '("annex-file") '("--to=repo1"))
      (magit-annex-tests-wait)
      (should-not (magit-annex-present-files)))
    (let ((default-directory repo1))
      (magit-annex-merge)
      (should (equal (magit-annex-present-files)
                     '("annex-file"))))))

(ert-deftest magit-annex-copy-files ()
  (magit-annex-with-test-repo-pair
    (let ((default-directory repo2))
      (magit-annex-tests-modify-file "annex-file")
      (magit-annex-add "annex-file")
      (magit-call-git "commit" "-m" "annex commit")
      (magit-annex-sync)
      (magit-annex-tests-wait)
      (magit-annex-copy-files '("annex-file") '("--to=repo1"))
      (magit-annex-tests-wait)
      (should (equal (magit-annex-present-files)
                     '("annex-file"))))
    (let ((default-directory repo1))
      (magit-annex-merge)
      (should (equal (magit-annex-present-files)
                     '("annex-file"))))))

(ert-deftest magit-annex-unlock-lock-files ()
  (magit-annex-with-test-repo
    (magit-annex-tests-modify-file "annex-file")
    (magit-annex-add "annex-file")
    (magit-call-git "commit" "-m" "annex commit")
    (should-not (magit-annex-unlocked-files))
    (magit-annex-unlock-files '("annex-file"))
    (magit-annex-tests-wait)
    (should (equal (magit-annex-unlocked-files)
                   '("annex-file")))
    (magit-annex-lock-files '("annex-file") '("--force"))
    (magit-annex-tests-wait)
    (should-not (magit-annex-unlocked-files))))
