FROM golang:1.25-bookworm AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /out/simulator ./tools/simulator

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/simulator /simulator
ENTRYPOINT ["/simulator"]
