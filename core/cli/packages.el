;; -*- no-byte-compile: t; -*-
;;; core/cli/packages.el

(defcli! (update u)
  ((discard-p ["--discard"] "All local changes to packages are discarded"))
  "Updates packages.

This works by fetching all installed package repos and checking the distance
between HEAD and FETCH_HEAD. This can take a while.

This excludes packages whose `package!' declaration contains a non-nil :freeze
or :ignore property."
  (straight-check-all)
  (let ((doom-auto-discard discard-p))
    (doom-cli-reload-core-autoloads)
    (when (doom-cli-packages-update)
      (doom-cli-reload-package-autoloads))
    t))

(defcli! (build b)
    ((rebuild-p ["-r"] "Only rebuild packages that need rebuilding"))
  "Byte-compiles & symlinks installed packages.

This ensures that all needed files are symlinked from their package repo and
their elisp files are byte-compiled. This is especially necessary if you upgrade
Emacs (as byte-code is generally not forward-compatible)."
  (when (doom-cli-packages-build (not rebuild-p))
    (doom-cli-reload-package-autoloads))
  t)

(defcli! (purge p)
    ((nobuilds-p ["-b" "--no-builds"] "Don't purge unneeded (built) packages")
     (noelpa-p   ["-p" "--no-elpa"]   "Don't purge ELPA packages")
     (norepos-p  ["-r" "--no-repos"]  "Don't purge unused straight repos")
     (regraft-p  ["-g" "--regraft"]   "Regraft git repos (ie. compact them)"))
  "Deletes orphaned packages & repos, and compacts them.

Purges all installed ELPA packages (as they are considered temporary). Purges
all orphaned package repos and builds. If -g/--regraft is supplied, the git
repos among them will be regrafted and compacted to ensure they are as small as
possible.

It is a good idea to occasionally run this doom purge -g to ensure your package
list remains lean."
  (straight-check-all)
  (when (doom-cli-packages-purge
         (not noelpa-p)
         (not norepos-p)
         (not nobuilds-p)
         regraft-p)
    (doom-cli-reload-package-autoloads))
  t)

;; (defcli! rollback () ; TODO doom rollback
;;   "<Not implemented yet>"
;;   (user-error "Not implemented yet, sorry!"))


;;
;;; Library

(defun doom--straight-recipes ()
  (let (recipes)
    (dolist (recipe (hash-table-values straight--recipe-cache))
      (straight--with-plist recipe (local-repo type)
        (when (and local-repo (not (eq type 'built-in)))
          (push recipe recipes))))
    (nreverse recipes)))

(defmacro doom--map-recipes (recipes binds &rest body)
  (declare (indent 2))
  (let ((recipe-var  (make-symbol "recipe"))
        (recipes-var (make-symbol "recipes")))
    `(let* ((,recipes-var ,recipes)
            (built ())
            (straight-use-package-pre-build-functions
             (cons (lambda (pkg) (cl-pushnew pkg built :test #'equal))
                   straight-use-package-pre-build-functions)))
       (dolist (,recipe-var ,recipes-var)
         (cl-block nil
           (straight--with-plist (append (list :recipe ,recipe-var) ,recipe-var)
               ,(doom-enlist binds)
             ,@body)))
       (nreverse built))))

(defun doom-cli-packages-install ()
  "Installs missing packages.

This function will install any primary package (i.e. a package with a `package!'
declaration) or dependency thereof that hasn't already been."
  (straight--transaction-finalize)
  (print! (start "Installing packages..."))
  (print-group!
   (if-let (built
            (doom--map-recipes (doom--straight-recipes)
                (recipe package type local-repo)
              (condition-case-unless-debug e
                  (progn
                    (straight-use-package (intern package))
                    (when-let* ((newcommit (cdr (assoc local-repo doom-pinned-packages)))
                                (oldcommit (straight-vc-get-commit type local-repo)))
                      (unless (string-match-p (concat "^" newcommit) oldcommit)
                        (unless (straight-vc-commit-present-p recipe newcommit)
                          (straight-vc-fetch-from-remote recipe))
                        (if (straight-vc-commit-present-p recipe newcommit)
                            (progn
                              (print! (success "Checking out %s to %s")
                                      package (substring newcommit 0 8))
                              (straight-vc-check-out-commit recipe newcommit)
                              (straight-rebuild-package package t))
                          (ignore-errors
                            (delete-directory (straight--repos-dir package) 'recursive))
                          (straight-use-package (intern package))))))
                (error
                 (signal 'doom-package-error
                         (list package e (straight--process-get-output)))))))
       (print! (success "Installed %d packages")
               (length built))
     (print! (info "No packages need to be installed"))
     nil)))


(defun doom-cli-packages-build (&optional force-p)
  "(Re)build all packages."
  (straight--transaction-finalize)
  (print! (start "(Re)building %spackages...") (if force-p "all " ""))
  (print-group!
   (let ((straight-check-for-modifications
          (when (file-directory-p (straight--modified-dir))
            '(find-when-checking)))
         (straight--allow-find
          (and straight-check-for-modifications
               (executable-find straight-find-executable)
               t))
         (straight--packages-not-to-rebuild
          (or straight--packages-not-to-rebuild (make-hash-table :test #'equal)))
         (straight--packages-to-rebuild
          (or (if force-p :all straight--packages-to-rebuild)
              (make-hash-table :test #'equal))))
     (unless force-p
       (straight--make-package-modifications-available))
     (if-let (built
              (doom--map-recipes (doom--straight-recipes) (package)
                (straight-use-package (intern package))))
         (print! (success "Rebuilt %d package(s)") (length built))
       (print! (success "No packages need rebuilding"))
       nil))))


(defun doom-cli-packages-update ()
  "Updates packages."
  (straight--transaction-finalize)
  (print! (start "Updating packages (this may take a while)..."))
  (let* ((straight--repos-dir (straight--repos-dir))
         (straight--packages-to-rebuild (make-hash-table :test 'equal))
         (updated-repos (make-hash-table :test 'equal))
         (recipes (doom--straight-recipes))
         (total (length recipes))
         (i 0)
         errors)
    ;; TODO Log this somewhere?
    (doom--map-recipes recipes (recipe package type local-repo)
      (cl-incf i)
      (print-group!
       (unless (straight--repository-is-available-p recipe)
         (print! (error "(%d/%d) Couldn't find local repo for %s!")
                 i total package)
         (cl-return))
       (when (gethash local-repo updated-repos)
         (puthash package t straight--packages-to-rebuild)
         (ignore-errors (delete-directory (straight--build-dir package) 'recursive))
         (print! (success "(%d/%d) %s was updated indirectly (with %s)")
                 i total package local-repo)
         (cl-return))
       (let ((default-directory (straight--repos-dir local-repo))
             (esc (if doom-debug-mode "" "\033[1A")))
         (unless (file-in-directory-p default-directory straight--repos-dir)
           (print! (warn "(%d/%d) Skipping %s because it is local")
                   i total package)
           (cl-return))
         ;; FIXME Dear lord refactor me
         (condition-case-unless-debug e
             (let ((commit (straight-vc-get-commit type local-repo))
                   (newcommit (cdr (assoc local-repo doom-pinned-packages))))
               (and (stringp newcommit)
                    (string-match-p (concat "^" newcommit) commit)
                    (print! (success "\033[K(%d/%d) %s is up-to-date...%s")
                            i total package esc)
                    (cl-return))
               (unless (or (and (stringp newcommit)
                                (straight-vc-commit-present-p recipe newcommit)
                                (print! (start "\033[K(%d/%d) Checking out %s (%s)...%s")
                                        i total package (substring newcommit 0 7) esc))
                           (and (print! (start "\033[K(%d/%d) Fetching %s...%s")
                                        i total package esc)
                                (straight-vc-fetch-from-remote recipe)))
                 (print! (warn "\033[K(%d/%d) Failed to fetch %s")
                         i total (or local-repo package))
                 (cl-return))
               (let ((output (straight--process-get-output)))
                 (if (stringp newcommit)
                     (if (straight-vc-commit-present-p recipe newcommit)
                         (straight-vc-check-out-commit recipe newcommit)
                       (print! (start "\033[K(%d/%d) Re-cloning %s...%s") i total local-repo esc)
                       (ignore-errors
                         (delete-directory (straight--repos-dir package) 'recursive))
                       (straight-use-package (intern package) nil 'no-build))
                   (straight-merge-package package)
                   (setq newcommit (straight-vc-get-commit type local-repo)))
                 (when (string-match-p (concat "^" newcommit) commit)
                   (cl-return))
                 (print! (start "\033[K(%d/%d) Updating %s...%s") i total local-repo esc)
                 (puthash local-repo t updated-repos)
                 (puthash package t straight--packages-to-rebuild)
                 (ignore-errors
                   (delete-directory (straight--build-dir package) 'recursive))
                 (print-group!
                  (unless (string-empty-p output)
                    (print! (info "%s") output))
                  (when (eq type 'git)
                    (straight--call
                     "git" "log" "--oneline" "--no-merges"
                     newcommit (concat "^" commit))
                    (print-group!
                     (print! "%s" (straight--process-get-output)))))
                 (print! (success "(%d/%d) %s updated (%s -> %s)") i total
                         (or local-repo package)
                         (substring commit 0 7)
                         (substring newcommit 0 7))))
           (user-error
            (signal 'user-error (error-message-string e)))
           (error
            (print! (warn "\033[K(%d/%d) Encountered error with %s" i total package))
            (print-group!
             (print! (error "%s" e))
             (print-group! (print! (info "%s" (straight--process-get-output)))))
            (push package errors)))))
      (princ "\033[K")
      (when errors
        (print! (error "Encountered %d error(s), the offending packages: %s")
                (length errors) (string-join errors ", ")))
      (if (hash-table-empty-p straight--packages-to-rebuild)
          (ignore
           (print! (success "All %d packages are up-to-date")
                   (hash-table-count straight--repo-cache)))
        (print! (success "Updated %d package(s)")
                (hash-table-count straight--packages-to-rebuild))
        (doom-cli-packages-build)
        t))))


;;; PURGE (for the emperor)
(defun doom--cli-packages-purge-build (build)
  (let ((build-dir (straight--build-dir build)))
    (delete-directory build-dir 'recursive)
    (if (file-directory-p build-dir)
        (ignore (print! (error "Failed to purg build/%s" build)))
      (print! (success "Purged build/%s" build))
      t)))

(defun doom--cli-packages-purge-builds (builds)
  (if (not builds)
      (progn (print! (info "No builds to purge"))
             0)
    (print! (start "Purging straight builds..." (length builds)))
    (print-group!
     (length
      (delq nil (mapcar #'doom--cli-packages-purge-build builds))))))

(defun doom--cli-packages-regraft-repo (repo)
  (let ((default-directory (straight--repos-dir repo)))
    (if (not (file-directory-p ".git"))
        (ignore (print! (warn "\033[Krepos/%s is not a git repo, skipping" repo)))
      (let ((before-size (doom-directory-size default-directory)))
        (straight--call "git" "reset" "--hard")
        (straight--call "git" "clean" "-ffd")
        (if (not (car (straight--call "git" "replace" "--graft" "HEAD")))
            (print! (info "\033[Krepos/%s is already compact\033[1A" repo))
          (straight--call "git" "gc")
          (print! (success "\033[KRegrafted repos/%s (from %0.1fKB to %0.1fKB)")
                  repo before-size (doom-directory-size default-directory))
          (print-group! (print! "%s" (straight--process-get-output)))))
      t)))

(defun doom--cli-packages-regraft-repos (repos)
  (if (not repos)
      (progn (print! (info "No repos to regraft"))
             0)
    (print! (start "Regrafting %d repos..." (length repos)))
    (let ((before-size (doom-directory-size (straight--repos-dir))))
      (print-group!
       (prog1 (delq nil (mapcar #'doom--cli-packages-regraft-repo repos))
         (princ "\033[K")
         (let ((after-size (doom-directory-size (straight--repos-dir))))
           (print! (success "Finished regrafting. Size before: %0.1fKB and after: %0.1fKB (%0.1fKB)")
                   before-size after-size
                   (- after-size before-size))))))))

(defun doom--cli-packages-purge-repo (repo)
  (let ((repo-dir (straight--repos-dir repo)))
    (delete-directory repo-dir 'recursive)
    (ignore-errors
      (delete-file (straight--modified-file repo)))
    (if (file-directory-p repo-dir)
        (ignore (print! (error "Failed to purge repos/%s" repo)))
      (print! (success "Purged repos/%s" repo))
      t)))

(defun doom--cli-packages-purge-repos (repos)
  (if (not repos)
      (progn (print! (info "No repos to purge"))
             0)
    (print! (start "Purging straight repositories..."))
    (print-group!
     (length
      (delq nil (mapcar #'doom--cli-packages-purge-repo repos))))))

(defun doom--cli-packages-purge-elpa ()
  (require 'core-packages)
  (let ((dirs (doom-files-in package-user-dir :type t :depth 0)))
    (if (not dirs)
        (progn (print! (info "No ELPA packages to purge"))
               0)
      (print! (start "Purging ELPA packages..."))
      (dolist (path dirs (length dirs))
        (condition-case e
            (print-group!
             (if (file-directory-p path)
                 (delete-directory path 'recursive)
               (delete-file path))
             (print! (success "Deleted %s") (filename path)))
          (error
           (print! (error "Failed to delete %s because: %s")
                   (filename path)
                   e)))))))

(defun doom-cli-packages-purge (&optional elpa-p builds-p repos-p regraft-repos-p)
  "Auto-removes orphaned packages and repos.

An orphaned package is a package that isn't a primary package (i.e. doesn't have
a `package!' declaration) or isn't depended on by another primary package.

If BUILDS-P, include straight package builds.
If REPOS-P, include straight repos.
If ELPA-P, include packages installed with package.el (M-x package-install)."
  (print! (start "Purging orphaned packages (for the emperor)..."))
  (cl-destructuring-bind (&optional builds-to-purge repos-to-purge repos-to-regraft)
      (let ((rdirs (straight--directory-files (straight--repos-dir) nil nil 'sort))
            (bdirs (straight--directory-files (straight--build-dir) nil nil 'sort)))
        (list (cl-remove-if (doom-rpartial #'gethash straight--profile-cache)
                            bdirs)
              (cl-remove-if (doom-rpartial #'straight--checkhash straight--repo-cache)
                            rdirs)
              (cl-remove-if-not (doom-rpartial #'straight--checkhash straight--repo-cache)
                                rdirs)))
    (let (success)
      (print-group!
       (if (not builds-p)
           (print! (info "Skipping builds"))
         (and (/= 0 (doom--cli-packages-purge-builds builds-to-purge))
              (setq success t)
              (straight-prune-build-cache)))
       (if (not elpa-p)
           (print! (info "Skipping elpa packages"))
         (and (/= 0 (doom--cli-packages-purge-elpa))
              (setq success t)))
       (if (not repos-p)
           (print! (info "Skipping repos"))
         (and (/= 0 (doom--cli-packages-purge-repos repos-to-purge))
              (setq success t)))
       (if (not regraft-repos-p)
           (print! (info "Skipping regrafting"))
         (and (doom--cli-packages-regraft-repos repos-to-regraft)
              (setq success t)))
       success))))
