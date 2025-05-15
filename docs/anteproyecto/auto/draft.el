(TeX-add-style-hook
 "draft"
 (lambda ()
   (TeX-add-to-alist 'LaTeX-provided-class-options
                     '(("article" "a4" "11pt")))
   (TeX-run-style-hooks
    "latex2e"
    "~/mi-preamble-latex/mypreamble"
    "article"
    "art11")
   (LaTeX-add-labels
    "sec:intro"
    "sec:descripcion"))
 :latex)

