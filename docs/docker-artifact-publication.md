# Publicación de un único artefacto Docker

## Contrato

El workflow construye una sola vez con BuildKit y exporta un archivo OCI. Extrae
ese mismo archivo a un layout OCI para Trivy 0.71.1 (acción v0.36.0 fijada por SHA).
No vuelve a construir ni convierte el manifiesto a formato Docker. Comprueba los
SHA-256 de manifiesto, configuración y capas y la plataforma solicitada antes y
después del análisis; comprueba también el SHA-256 del archivo transferido.

El job de publicación solo recibe el artefacto tras un análisis satisfactorio y
lo compara con los outputs del job de análisis. Skopeo usa `--preserve-digests`;
si el registro exige una conversión, falla. Publica primero el SHA completo y
verifica por bytes tanto el manifiesto de esa etiqueta como la referencia por
digest. Solo entonces actualiza cada etiqueta mutable, verificándola también.
No hay fallback de conversión ni segunda compilación. Una discrepancia puede
haber creado la etiqueta SHA, pero impide actualizar las etiquetas mutables
siguientes. No hay atomicidad entre múltiples etiquetas en GHCR.

El artefacto de imagen solo se sube si habrá publicación; retención de un día.
No incluye contexto, tokens ni archivos de autenticación. El token de paquetes
se entrega al build como secreto de BuildKit, nunca como build-arg. Los permisos
para publicar se heredan del llamador (los consumidores actuales ya conceden
packages: write); el job de build los reduce a lectura. La autenticación del
registro solo existe en publicación y se elimina al terminar el paso.

## Entradas y compatibilidad

- `image-name`: nombre del paquete, sin registry ni etiqueta.
- `node-version`: conservado para compatibilidad, sin uso en Docker.
- `tag`: API heredada; por defecto latest. Un llamador con tag: staging sigue
  publicando únicamente SHA y staging, como antes.
- `push-latest`: true por defecto; false prohíbe latest. No convierte el tag
  heredado staging en una petición implícita de latest.
- `extra-tags`: etiquetas simples separadas por comas o espacios. Con
  push-latest: false, una petición explícita de latest provoca error.
- `push`: true por defecto. Los eventos pull_request y pull_request_target
  bloquean siempre publicación, aunque se solicite true. false permite validar.
- `platforms`: linux/amd64 por defecto. Se permite una sola plataforma Linux;
  los índices multiplataforma se rechazan para no publicar plataformas sin
  analizar. Ninguno de los siete consumidores actuales solicita múltiples.
- `context`: directorio que contiene Dockerfile; por defecto el directorio raíz.
  El self-test usa .github/fixtures/docker, con imagen scratch sintética.

Los helpers se descargan desde un commit inmutable del propio repositorio,
separado del checkout del consumidor y retirado del contexto antes de construir.
Al cambiar helpers hay que actualizar ambos pins en docker-build.yml después de
versionarlos. Esto evita ejecutar scripts controlados por el repositorio llamador.

## Herramientas y fuentes

Skopeo se instala y comprueba expresamente: paquete Ubuntu Noble amd64
`1.13.3+ds1-2ubuntu0.24.04.3`, en runner ubuntu-24.04. Si desaparece de los índices,
la instalación falla; no se elimina el pin. Actionlint del self-test se instala
con Go a la versión v1.7.7, con verificación del checksum database de Go.

- Formato OCI de Trivy: https://trivy.dev/docs/latest/target/container_image/#oci-layout
- Entrada input y versión de la acción: https://github.com/aquasecurity/trivy-action/blob/v0.36.0/action.yaml
- Paquete de Skopeo: https://packages.ubuntu.com/en/noble/skopeo
- Preservación de digests: https://manpages.ubuntu.com/manpages/noble/man1/skopeo-copy.1.html

La documentación declara compatibilidad de formatos; el self-test debe probarla
con las versiones fijadas. No se infiere que se haya ejecutado por leerla.

## Consumidores inspeccionados en lectura (2026-11-06)

| Repositorio | Entradas actuales | Comportamiento conservado |
| --- | --- | --- |
| sisforge-auth | image-name | SHA + latest |
| sisforge-billing | image-name | SHA + latest |
| sisforge-gateway | image-name | SHA + latest |
| sisforge-notifications | image-name | SHA + latest |
| siswrench-api | image-name | SHA + latest para el job existente |
| sisfork-api | tag: staging / latest | SHA + etiqueta heredada |
| sisfork-dashboard | tag: staging / latest | SHA + etiqueta heredada |

Se inspeccionaron sus workflows tanto localmente como mediante el conector GitHub;
no se modificaron los otros seis repositorios. Sus Dockerfiles usan bases públicas;
los consumidores que usan un paquete npm privado ya montan node_auth_token.

## Verificación local y límites (2026-11-06)

- OK: actionlint de docker-build.yml y docker-build-self-test.yml (YAML, expresiones
  y acciones), Bash -n, ShellCheck y contratos offline.
- Contratos offline ejecutados: etiquetas por defecto, etiqueta heredada staging,
  staging sin latest, rechazo de latest explícito, eventos de PR y push:false,
  blobs/manifiesto adulterados y manifiesto remoto incorrecto. El límite remoto
  usa un mock: demuestra el rechazo y ausencia de actualización mutable en el
  código; no demuestra compatibilidad con GHCR ni un digest publicado real.
- El daemon Docker no está disponible en este entorno (socket inexistente).
  BuildKit, exportación real, análisis de vulnerabilidades de imagen real con
  Trivy 0.71.1 y roundtrip real con Skopeo NO EJECUTADOS.
- OK: test-oci-format.sh con Trivy 0.71.1 lee un layout OCI scratch sintético
  y comprueba arquitectura amd64; usa solo scanner de secretos, sin base de
  vulnerabilidades. Esto verifica el parser, no el análisis de CVE de una imagen
  real ni el exportador BuildKit. El cache se aísla en un temporal y se elimina.
- Intento local con Trivy 0.71.1 sobre un layout scratch sintético: FALLÓ antes del
  análisis por ausencia de base de vulnerabilidades y uso offline. No valida
  cobertura de vulnerabilidades ni sustituye el self-test con BuildKit.
  Un primer intento del test de formato también falló por permisos del cache
  global; se repitió con cache temporal y pasó.
- Publicación real y lectura de manifiestos GHCR NO EJECUTADAS ni autorizadas en
  estas pruebas. No se publicaron imágenes ni se modificó latest.
- Los dos fetch fallaron por DNS. El conector confirmó que las referencias base
  remotas coincidían con las locales antes de crear las ramas.

## Integración y checks

1. Revisar esta PR y ejecutar Docker workflow self-test sin publicación.
2. Exigir contratos, builds scratch, Trivy y verificación local OCI en verde;
   en PR, comprobar además que push:true no produce published-digest.
3. Integrar la PR compartida en main mediante revisión humana, conservando los
   commits de helpers (merge commit). Los pins de checkout deben seguir alcanzables.
   Si se usa squash, antes de borrar la rama hay que repinear ambos checkouts al
   commit estable que contiene los helpers y validar esa corrección; no dejar
   como única referencia un commit huérfano de la rama eliminada.
4. En la PR de SisWrench sustituir la referencia temporal por el SHA estable del
   workflow compartido integrado. No dejar una rama de trabajo como dependencia.
5. Revisar e integrar SisWrench hacia deploy/staging-nas. Ese push es el primer
   punto que puede publicar una imagen de staging; requiere autorización humana
   de integración y no se realiza durante estas pruebas.
6. Verificar en esa ejecución autorizada el digest y ambas etiquetas. El futuro
   despliegue debe consumir image@sha256:..., nunca resolver staging en cada paso.

No hay checks observados en GitHub para los nuevos workflows todavía. Nombres
estimados: Workflow contracts; Default tags, no publication / Build · Trivy · Verify
OCI; Staging tags, no publication / Build · Trivy · Verify OCI; PR cannot request
publication / Build · Trivy · Verify OCI; Verify PR publication was skipped.
Confirmar los nombres completos en una ejecución antes de fijarlos en un ruleset.
La publicación real permanece sin validar hasta una ejecución autorizada.
