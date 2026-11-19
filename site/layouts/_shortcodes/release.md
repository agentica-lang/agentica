{{- if not site.Params.version }}{{ errorf "site.Params.version is not set: build with make site, which reads the VERSION file" }}{{ end -}}
{{ i18n "release_intro" (dict "Version" (partial "version.html") "URL" (partial "release-url.html") "All" (printf "%s/releases" site.Params.repo)) }}
