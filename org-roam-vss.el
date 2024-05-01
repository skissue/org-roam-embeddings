;;; org-roam-vss.el --- Vector similarity search for Org Roam -*- lexical-binding: t -*-

;; Author: skissue
;; Version: 0.1.0
;; Package-Requires: ((emacs "29") (org-roam "2.2.2") (llm "0.13.0"))
;; Homepage: https://github.com/skissue/org-roam-vss


;; This file is not part of GNU Emacs

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.


;;; Commentary:

;; (WIP) Vector similarity search for Org Roam based on an embeddings database.

;;; Code:

(require 'org-roam)
(require 'llm)

(defvar org-roam-vss--db-connection nil
  "`org-roam-vss' SQLite database connection.")

(defcustom org-roam-vss-db-location (expand-file-name
                                     "org-roam-vss.db"
                                     (file-name-directory org-roam-db-location))
  "`org-roam-vss' SQLite database location."
  :type 'file)

(defcustom org-roam-vss-sqlite-vss-dir "./"
  "The directory where the 'sqlite-vss' libraries are stored."
  :type 'directory)

(defcustom org-roam-vss-llm nil
  "An instance of `llm' to use to generate embeddings."
  :type '(sexp :validate #'cl-struct-p))

(defcustom org-roam-vss-dimensions 768
  "The number of dimensions in the embedding vector generated by
`org-roam-vss-llm'. If this changes, the entire database MUST be
regenerated."
  :type 'number)

(defcustom org-roam-vss-node-content-function #'org-roam-vss-node-whole-document
  "Function to extract documents from a node. Should take a single
argument NODE, and return a list of cons cells where the car is
the point where the document should start and the cdr is where
the document should end. Will be called with NODE's file as the
active buffer.

Defaults to `org-roam-vss-node-whole-document', which returns the
entire node's content as one document."
  :type 'function)

(defun org-roam-vss--query (select query &rest values)
  "Simple wrapper around `sqlite-execute' that uses
`org-roam-vss--db-connection' for the connection and ensures that
the connection has been initialized.

Executes QUERY with VALUES interpolated. Uses `sqlite-select' if
SELECT is non-nil."
  (org-roam-vss--maybe-connect)
  (if select
      (sqlite-select org-roam-vss--db-connection query values)
    (sqlite-execute org-roam-vss--db-connection query values)))

(defun org-roam-vss--maybe-connect ()
  "Call `org-roam-vss--db-connect' if
 `org-roam-vss--db-connection' hasn't been initialized yet."
  (unless org-roam-vss--db-connection
    (org-roam-vss--db-connect)))

(defun org-roam-vss--db-connect ()
  "Connect to SQLite database, set up 'sqlite-vss', and save connection in
`org-roam-vss--db-connection'."
  (setq org-roam-vss--db-connection (sqlite-open org-roam-vss-db-location))
  (sqlite-load-extension org-roam-vss--db-connection
                         (expand-file-name "vector0.so" org-roam-vss-sqlite-vss-dir))
  (sqlite-load-extension org-roam-vss--db-connection
                         (expand-file-name "vss0.so" org-roam-vss-sqlite-vss-dir))
  (org-roam-vss--create-table))

(defun org-roam-vss--create-table ()
  "Create 'roam_nodes' and 'vss_roam' tables if needed."
  (org-roam-vss--query
   ;; HACK For some reason, interpolating the dimensions doesn't work
   nil (format "CREATE VIRTUAL TABLE IF NOT EXISTS vss_roam USING vss0(embedding(%d))"
               org-roam-vss-dimensions)) 
  (org-roam-vss--query
   nil "CREATE TABLE IF NOT EXISTS roam_nodes
        (id INTEGER PRIMARY KEY AUTOINCREMENT,
         node_id TEXT,
         start INT,
         end INT)")
  (org-roam-vss--query
   nil "CREATE INDEX IF NOT EXISTS node_id_index ON roam_nodes(node_id)"))

(defun org-roam-vss--db-disconnect ()
  "Disconnect from SQLite database."
  (when org-roam-vss--db-connection
    (sqlite-close org-roam-vss--db-connection)
    (setq org-roam-vss--db-connection nil)))

(defmacro org-roam-vss--with-embedding (text &rest body)
  "Wrapper around `llm-embedding-async' that executes BODY with the
embedding of TEXT bound to 'embedding'."
  `(llm-embedding-async
    org-roam-vss-llm ,text
    (lambda (embedding) ,@body)
    (lambda (sig err)
      (signal sig (list err)))))
(put 'org-roam-vss--with-embedding 'lisp-indent-function 'defun)

(defun org-roam-vss-node-whole-document (node)
  "Return the entire body of NODE as a single document. Simple, but
may not work well if you have nodes with large amounts of
content."
  (goto-char (org-roam-node-point node))
  (org-roam-end-of-meta-data)
  (list (cons (point) (point-max))))

(defun org-roam-vss-node-paragraph-documents (node)
  "Return every paragraph from the body of NODE as an individual
document. Paragraphs are determined by two consecutive newlines."
  (save-excursion
    (goto-char (org-roam-node-point node))
    (org-roam-end-of-meta-data)
    (cl-loop while (< (point) (point-max))
             for start = (point)
             and end = (progn
                         (re-search-forward "\n\n" nil :to-end)
                         (point))
             collect (cons start end))))

(defun org-roam-vss--clear-embeddings (id)
  "Clear all embeddings for the node with ID from the database."
  (with-sqlite-transaction org-roam-vss--db-connection
    (let ((rows (org-roam-vss--query
                 :select "SELECT id FROM roam_nodes WHERE node_id = ?"
                 id)))
      (dolist (row rows)
        (org-roam-vss--query
         nil "DELETE FROM vss_roam WHERE rowid = ?"
         (car row)))
      (org-roam-vss--query
       nil "DELETE FROM roam_nodes WHERE node_id = ?"
       id))))

(defun org-roam-vss--handle-returned-embedding (id document embedding)
  "Handle a returned embedding, ready to be inserted into the SQLite
database."
  (with-sqlite-transaction org-roam-vss--db-connection
    (let ((rowid (caar
                  (org-roam-vss--query
                   nil "INSERT INTO roam_nodes(node_id, start, end)
                        VALUES (?, ?, ?) RETURNING id"
                   id (car document) (cdr document)))))
      (org-roam-vss--query
       nil "INSERT INTO vss_roam(rowid, embedding) VALUES (?, ?)"
       rowid (json-encode embedding))))
  (message "Embeddings updated!"))

;;;###autoload
(defun org-roam-vss-update-embeddings (node)
  "Update or create the embeddings for the Org Roam node NODE.
 When called interactively, uses the node at point.
 Processes embedding using
 `org-roam-vss--handle-returned-embedding'."
  (interactive (list (org-roam-node-at-point)))
  (org-roam-vss--maybe-connect)
  (unless node
    (user-error "No valid node found."))
  (org-roam-vss--clear-embeddings (org-roam-node-id node))
  (org-roam-with-file (org-roam-node-file node) :kill
      (dolist (document (funcall org-roam-vss-node-content-function node))
        (org-roam-vss--with-embedding (buffer-substring-no-properties
                                       (car document)
                                       (cdr document))
          (org-roam-vss--handle-returned-embedding
           (org-roam-node-id node) document embedding)))))

;;;###autoload
(defun org-roam-vss-update-all ()
  "Update embeddings for all nodes."
  (interactive)
  (dolist (node (org-roam-node-list))
    (org-roam-vss-update-embeddings node)))

;;;###autoload
(defun org-roam-vss-clear-db (arg)
  "Clear all entries from embedding database. With prefix
 argument ARG, don't request user confirmation."
  (interactive "P")
  (when (or arg
            (yes-or-no-p "Really clear database?"))
    (org-roam-vss--query
     nil "DROP TABLE roam_nodes")
    (org-roam-vss--query
     nil "DROP TABLE vss_roam")
    (org-roam-vss--create-table)))

;;;###autoload
(defun org-roam-vss-search (query)
  "Search for all embeddings that are similar to QUERY."
  (interactive "sQuery: ")
  (org-roam-vss--with-embedding query
    (let* ((rows (org-roam-vss--query
                  ;; HACK When doing a JOIN, sqlite-vss complains about the lack
                  ;; of a LIMIT clause even when it is present, so use the old
                  ;; way of doing it instead.
                  :select "SELECT node_id, start, end, distance FROM vss_roam
                           JOIN roam_nodes ON vss_roam.rowid = roam_nodes.id
                           WHERE vss_search(embedding, vss_search_params(json(?), 20))"
                  (json-encode embedding)))
           (buffer (get-buffer-create "*VSS Search Results*"))
           (inhibit-read-only t))
      ;; Taken from `org-roam-buffer-render-contents'.
      (switch-to-buffer buffer)
      (erase-buffer)
      (org-roam-mode)
      (org-roam-buffer-set-header-line-format query)
      (dolist (row rows)
        (cl-destructuring-bind (id start end dist) row
          (let ((node (org-roam-node-from-id id)))
            (magit-insert-section (org-roam-backlinks)
              (magit-insert-heading (format "%s (%d)"
                                            (org-roam-node-title node)
                                            (round dist)))
              (insert
               (org-roam-fontify-like-in-org-mode
                (org-roam-with-file (org-roam-node-file node) :kill
                  (buffer-substring-no-properties start end)))))))))))

(provide 'org-roam-vss)

;;; org-roam-vss.el ends here
