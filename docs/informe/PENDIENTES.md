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
- [x] Calificar en la placa el bitstream 0.1.0+8a6d847 y fijarlo en release/manifest.json
      (firmware_development 4e7a67f; qualify 0.1.0-rc3 OK, 19,3–19,5 fps)
- [ ] Firma de actualizaciones con GPG (el autor genera la clave) — cap. 7, distribución
- [x] "Bug" de matrices de cuantización: estaba en la referencia (mpeg2dec), no en el núcleo
      (hw d91aecd, bitácora 49) — caps. 2, 10, 11 y anexo C actualizados
- [x] mei-16-long y mei-16v2 "sin escritura": son MPEG-1, fuera de alcance — cap. 10
- [x] tcela-15 "sin escritura": decodifica bien (gris uniforme); era el criterio de
      buffer vacío de framecmp (hw 1f80151) — bit-exacto, cap. 10 y anexo C
- [ ] (opcional) deriva restante en 5 flujos: sony-ct1, hhi-burst-long, nokia6-60, tcela-10, tcela-14
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
