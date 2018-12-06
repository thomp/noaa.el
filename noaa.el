;;; noaa.el --- Get NOAA weather data -*- lexical-binding: t -*-

;; Copyright (C) 2017,2018 David Thompson
;; Author: David Thompson
;; Version: 0.1
;; Keywords:
;; Homepage: https://github.com/thomp/noaa
;; URL: https://github.com/thomp/noaa
;; Package-Requires: ((request "0.2.0") (cl-lib "0.5") (emacs "24") (dash "2.14.1"))

;;; Commentary:

;; This package provides a way to view an NOAA weather
;; forecast for a specific geographic location.

;;; Code:

(require 'cl-lib)
(require 'dash)
(require 'json)
(require 'request)

(defgroup noaa ()
  "View an NOAA weather forecast for a specific geographic location."
  :group 'external)

(defcustom noaa-latitude 36.7478
  "The latitude corresponding to the location of interest."
  :group 'noaa
  :type '(number))

(defcustom noaa-longitude -119.771
  "The latitude corresponding to the location of interest."
  :group 'noaa
  :type '(number))

(defvar noaa-buffer-spec "*noaa.el*"
  "Buffer or buffer name.")

(defvar noaa-display-styles '(default extended terse)
  "List of symbols indicating the various manners in which forecast data can be presented. The first member of the list is the currently active style.")

(defface noaa-face-date '((t (:foreground "#30c2ba")))
  "Face used for date.")

(defface noaa-face-short-forecast '((t (:foreground "grey")))
  "Face used for short forecast text.")

(defface noaa-face-temp '((t (:foreground "#cfd400")))
  "Face used for temperature.")

;; Forecast data for a specified time range
(defstruct noaa-forecast
  start-time
  end-time
  day-number
  detailed-forecast
  short-forecast
  name
  temp
  temp-trend
  temp-unit
  wind-speed
  wind-direction)

(defvar noaa-last-forecast
  nil
  "A set of NOAA-FORECAST structs describing the last forecast retrieved.")

(defvar noaa-last-forecast-raw
  nil
  "The server response associated with the last forecast request.")

;;;###autoload
(defun noaa ()
  "Request weather forecast data. Display the data in the buffer specified by ‘noaa-buffer-spec’."
  (interactive)
  ;; Honor CALENDAR- values if NOAA-LATITUDE and NOAA-LONGITUDE have
  ;; not been specified
  (when (not (and (numberp noaa-latitude)
		  (numberp noaa-longitude)))
    (when (and (numberp calendar-latitude)
	       (numberp calendar-longitude))
      (message "Using CALENDAR-LATITUDE and CALENDAR-LATITUDE values")
      (setf noaa-latitude calendar-latitude
	    noaa-longitude calendar-longitude)))
  (cond ((and (numberp noaa-latitude)
	      (numberp noaa-longitude))
	 (noaa-url-retrieve (noaa-url noaa-latitude noaa-longitude)))
	(t
	 (message "To use NOAA, first set NOAA-LATITUDE and NOAA-LONGITUDE."))))

(defun noaa-aval (alist key)
  "Utility function to retrieve value associated with key KEY in alist ALIST."
  (let ((pair (assoc key alist)))
    (if pair
	(cdr pair)
      nil)))

(defun noaa-display-last-forecast ()
  (interactive)
  (erase-buffer)
  (let (
	;; LAST-DAY-NUMBER is used for aesthetics --> separate data by day
	(last-day-number -1)
	(day-field-width 16)
	(temp-field-width 5)
	(forecast-length (length noaa-last-forecast)))
    (dotimes (index forecast-length)
      (let ((day-forecast (elt noaa-last-forecast index)))
	(noaa-insert-day-forecast
	 day-forecast
	 (and (noaa-day-forecast-day-number day-forecast)
	      last-day-number
	      (= (noaa-day-forecast-day-number day-forecast)
		 last-day-number)))
	(setq last-day-number (noaa-day-forecast-day-number day-forecast))))
    (beginning-of-buffer)))

(defun noaa-insert-day-forecast (noaa-day-forecast last-day-p)
  (let ((style (first noaa-display-styles)))
    (cond ((eq style 'terse)
	   (unless last-day-p
	     (insert (propertize (format "%s " (substring (noaa-forecast-name noaa-forecast) 0 2))
				 'face 'noaa-face-date)))
	   (insert (propertize (format "%s " (noaa-forecast-temp noaa-forecast))
			       'face 'noaa-face-temp)))
	  ((eq style 'default)
	   (let ((day-field-width 16)
		 (temp-field-width 5))
	     ;; simple output w/some alignment
	     (unless last-day-p
	       (newline))
	     (insert (propertize (format "%s" (noaa-forecast-name noaa-forecast)) 'face 'noaa-face-date))
	     (move-to-column day-field-width t)
	     (insert (propertize (format "% s" (noaa-forecast-temp noaa-forecast)) 'face 'noaa-face-temp))
	     (move-to-column (+ day-field-width temp-field-width) t)
	     (insert (propertize (format "%s" (noaa-forecast-short-forecast noaa-forecast)) 'face 'noaa-face-short-forecast))
	     (newline)))
	  ((eq style 'extended)
	   (let ((day-field-width 16)
		 (temp-field-width 5))
	     (insert (propertize (format "%s" (noaa-forecast-name noaa-forecast)) 'face 'noaa-face-date))
	     (move-to-column day-field-width t)
	     (insert (propertize (format "% s" (noaa-forecast-temp noaa-forecast)) 'face 'noaa-face-temp))
	     (newline) (newline)
	     (insert (propertize (format "%s" (noaa-forecast-detailed-forecast noaa-forecast)) 'face 'noaa-face-short-forecast))
	     (newline) (newline)))
	  (t
	   (error "Unrecognized style")))))

(defun noaa-handle-noaa-result (result)
  "Handle the data described by RESULT (presumably the result of an HTTP request for NOAA forecast data). Return a list of periods."
  (switch-to-buffer noaa-buffer-spec)
  ;; retrieve-fn accepts two arguments: a key-value store and a key
  ;; retrieve-fn returns the corresponding value
  (let ((retrieve-fn 'noaa-aval))
    (let ((properties (funcall retrieve-fn result 'properties)))
      (if (not properties)
	  (message "Couldn't find properties. The NOAA API spec may have changed.")
	(funcall retrieve-fn properties 'periods)))))

;; emacs built-ins aren't there yet for handling ISO8601 values -- leaning on date is non-portable but works nicely for systems where date is available
(defun noaa-iso8601-to-day (iso8601-string)
  "Return a day value for the time specified by ISO8601-STRING."
  (elt (parse-time-string (shell-command-to-string (format "date -d %s --iso-8601=date" iso8601-string))) 3))

;;;###autoload
(defun noaa-quit ()
  "Leave the buffer specified by ‘noaa-buffer-spec’."
  (interactive)
  (kill-buffer noaa-buffer-spec))

(defun noaa-clear-last-forecast ()
  (setf noaa-last-forecast nil))

(defun noaa-set-last-forecast (periods)
  (message "periods: %S " periods)
  (noaa-clear-last-forecast)
  ;; retrieve-fn accepts two arguments: a key-value store and a key
  ;; retrieve-fn returns the corresponding value
  (let ((retrieve-fn 'noaa-aval)
	(number-of-periods (length periods)))
    (setf noaa-last-forecast (make-list (length periods) nil))
    (dotimes (i number-of-periods)
      (let ((period (elt periods i)))
	(let ((start-time (funcall retrieve-fn period 'startTime)))
	  (let ((day-number (noaa-iso8601-to-day start-time))
		(detailed-forecast (funcall retrieve-fn period 'detailedForecast))
		(end-time (funcall retrieve-fn period 'endTime))
		;; NAME is descriptive. It is not always the name of a week day. Exaples of valid values include "This Afternoon", "Thanksgiving Day", or "Wednesday Night". For an hourly forecast, it may simply be the empty string.
		(name (funcall retrieve-fn period 'name))
		(temp (funcall retrieve-fn period 'temperature))
		(short-forecast (funcall retrieve-fn period 'shortForecast)))
	    (setf (elt noaa-last-forecast i)
		  (make-noaa-forecast :start-time start-time :end-time nil :day-number day-number :name name :temp temp :detailed-forecast detailed-forecast :short-forecast short-forecast))))))))

(defun noaa-url (&optional latitude longitude hourlyp)
  "Return a string representing a URL. LATITUDE and LONGITUDE should be numbers."
  (let (;; development only
	(hourlyp t)
	(url-string (format "https://api.weather.gov/points/%s,%s/forecast" (or latitude noaa-latitude) (or longitude noaa-longitude))))
    (when hourlyp
      (setf url-string
	    (concatenate 'string url-string "/hourly")))
    url-string))

(defun noaa-url-retrieve (url &optional http-callback)
  "Return the buffer containing only the 'raw' body of the HTTP response. Call HTTP-CALLBACK with the buffer as a single argument."
  (noaa-url-retrieve-tkf-emacs-request url http-callback))

;; async version relying on tfk emacs-request library
(defun noaa-url-retrieve-tkf-emacs-request (&optional url http-callback)
  (request (or url (noaa-url noaa-latitude noaa-longitude))
	   :parser 'buffer-string ;'json-read
	   :error (function*
		   (lambda (&key data error-thrown response symbol-status &allow-other-keys)
		     (message "data: %S " data) 
		     (message "symbol-status: %S " symbol-status)
		     (message "E Error response: %S " error-thrown)
		     (message "response: %S " response)))
	   :status-code '((500 . (lambda (&rest _) (message "Got 500 -- the NOAA server seems to be unhappy"))))
	   :success (or http-callback 'noaa-http-callback)))

;; forecast-http-callback
(cl-defun noaa-http-callback (&key data response error-thrown &allow-other-keys)
  (let ((noaa-buffer (get-buffer-create noaa-buffer-spec)))
    (switch-to-buffer noaa-buffer)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (and error-thrown (message (error-message-string error-thrown))))
    (goto-char (point-min))
    (let ((result (json-read-from-string data)))
      (setf noaa-last-forecast-raw result)
      (let ((periods (noaa-handle-noaa-result result)))
 	(noaa-set-last-forecast periods))
      (noaa-display-last-forecast)
      (noaa-mode))))

(cl-defun noaa-http-callback--simple (&key data response error-thrown &allow-other-keys)
  (let ((noaa-buffer (get-buffer-create noaa-buffer-spec)))
    (switch-to-buffer noaa-buffer)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (and error-thrown (message (error-message-string error-thrown)))
      (noaa-insert data))))

(defun noaa-parse-json-in-buffer ()
  "Parse and return the JSON object present in the buffer specified by ‘noaa-buffer-spec’."
  (switch-to-buffer noaa-buffer-spec)
  (json-read))

(defun noaa-insert (x)
  "Insert X into the buffer specified by ‘noaa-buffer-spec’."
  (switch-to-buffer noaa-buffer-spec)
  (insert x))

(defun noaa-next-style ()
  (interactive)
  ;; wouldn't hurt to add this to other (interactive) fns that should only operate within noaa-mode
  (unless (eq (current-buffer) (get-buffer noaa-buffer-spec))
    (display-warning :warning (format "Not in %s buffer" noaa-buffer-spec)))
  (setf noaa-display-styles (-rotate 1 noaa-display-styles)) ; dash provides -rotate
  (noaa-display-last-forecast))

;;
;; noaa mode
;;

;;;###autoload
(define-derived-mode noaa-mode text-mode "noaa"
  "Major mode for displaying NOAA weather data
\\{noaa-mode-map}
"
  )

(defvar noaa-mode-map (make-sparse-keymap)
  "Keymap for `noaa-mode'.")

(define-key noaa-mode-map (kbd "q") 'noaa-quit)
(define-key noaa-mode-map (kbd "n") 'noaa-next-style)

(provide 'noaa)
;;; noaa.el ends here
