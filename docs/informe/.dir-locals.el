;; AUCTeX: el informe usa fontspec, así que se compila con XeLaTeX; los
;; capítulos, anexos y la portada tienen como documento maestro a informe.tex.
((nil . ((TeX-engine . xetex)
         (TeX-master . "informe.tex")))
 ("capitulos" . ((nil . ((TeX-master . "../informe.tex")))))
 ("anexos"    . ((nil . ((TeX-master . "../informe.tex")))))
 ("portada"   . ((nil . ((TeX-master . "../informe.tex"))))))
