# syntax=docker/dockerfile:1.10
# Requested target: no SSH itself, only consumes the two SSH targets.
FROM ubuntu:jammy AS final
COPY --from=fetch-a /ws/result.txt /results/a.txt
COPY --from=fetch-b /ws/result.txt /results/b.txt
RUN cat /results/*.txt
