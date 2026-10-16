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

- [x] Verificación de temporización con relojes reales (hw 8a6d847: script,
      sincronizador de reset, set_clock_groups) — cap. 5 "Temporización"
- [ ] Calificar en la placa el bitstream 0.1.0+8a6d847 (cambió el RTL: sincronizador
      de reset) y fijarlo en release/manifest.json — antes de la release final
- [ ] Firma de actualizaciones con GPG (el autor genera la clave) — cap. 7, distribución
- [ ] Bug de carga de matrices de cuantización — cap. 2 "Limitaciones conocidas" y cap. 10
- [ ] Los 3 flujos "sin escritura" (mei-16-long, mei-16v2, tcela-15) — cap. 10
- [x] Manual de Referencia (Doxygen; reemplaza a la nota de aplicación) — firmware_development 6c7a6e3, sale en cada release — caps. 1, 7 y 11
- [ ] Release final: actualizar la versión citada — cap. 7; la tabla de
      entregables dice "próxima versión" para licencias y avisos de terceros
- [x] Archivo de licencia en la raíz (`LICENSE` MIT, `LICENSES.md`,
      `THIRD_PARTY_NOTICES.md`; firmware_development 3a57e51) — cap. 7

## Editorial

- [x] Siglas y convenciones
- [x] Sin referencias a plazos/cronograma del Anteproyecto (recomendación del tutor)
- [x] Revisión general de redacción y consistencia (2026-10-15)
- [x] Licencias de terceros del anexo F (revisadas por el autor)
