# Pendientes del Informe Final

Lista viva: se actualiza cada vez que se cierra o aparece algo. Las marcas
`\pendiente{}` del PDF (en rojo) son la otra fuente: `make` y buscar
"PENDIENTE" en `build/informe.pdf`.

## A cargo del autor

- [x] Agradecimientos
- [x] Mes de entrega: automático, siempre el mes en curso al compilar (`\fechaentrega` en `informe.tex`)
- [x] Tapa de Scribus (`portada/tapa-scribus.pdf`, para imprenta; el informe usa solo el panel de la tapa, seguido de la portada interior del Anexo 5)
- [ ] Texto oficial de la licencia del RIA (Ordenanza 1514), con firma (`portada/licencia-ria.tex`)

## Técnicos, antes de entregar

- [ ] Verificación de temporización con las restricciones de reloj (arreglar
      `build_mpeg2fpga_soc.tcl`) y reportar el margen por reloj — cap. 5, "Recursos utilizados"
- [ ] Firma de actualizaciones con GPG (el autor genera la clave) — cap. 7, distribución
- [ ] Bug de carga de matrices de cuantización — cap. 2 "Limitaciones conocidas" y cap. 10
- [ ] Los 3 flujos "sin escritura" (mei-16-long, mei-16v2, tcela-15) — cap. 10
- [ ] Nota de aplicación y documentación Doxygen — caps. 1 y 7 (tabla de entregables)
- [ ] Release final: actualizar la versión citada — cap. 7; la tabla de
      entregables dice "próxima versión" para licencias y avisos de terceros
- [x] Archivo de licencia en la raíz (`LICENSE` MIT, `LICENSES.md`,
      `THIRD_PARTY_NOTICES.md`; firmware_development 3a57e51) — cap. 7

## Editorial

- [x] Siglas y convenciones
- [x] Sin referencias a plazos/cronograma del Anteproyecto (recomendación del tutor)
- [x] Revisión general de redacción y consistencia (2026-10-15)
- [x] Licencias de terceros del anexo F (revisadas por el autor)
