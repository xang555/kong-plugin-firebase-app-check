package main

import (
	"context"
	"sync"
	"time"

	firebase "firebase.google.com/go/v4"
	"firebase.google.com/go/v4/appcheck"
	"github.com/Kong/go-pdk"
	"github.com/Kong/go-pdk/server"
	"github.com/patrickmn/go-cache"
	"google.golang.org/api/option"
)

// Config holds plugin configuration
type Config struct {
	ProjectID             string `json:"project_id"`
	ServiceAccountKeyFile string `json:"service_account_key_file"`
	CacheTTL              int    `json:"cache_ttl"`
}

var (
	verifier    *appcheck.Client
	initErr     error
	once        sync.Once
	cacheClient *cache.Cache
)

func New() interface{} { return &Config{} }

func initFirebaseAppCheck(conf *Config) (*appcheck.Client, error) {
	ctx := context.Background()
	opts := []option.ClientOption{}
	if conf.ServiceAccountKeyFile != "" {
		opts = append(opts, option.WithCredentialsFile(conf.ServiceAccountKeyFile))
	}
	app, err := firebase.NewApp(ctx, &firebase.Config{ProjectID: conf.ProjectID}, opts...)
	if err != nil {
		return nil, err
	}
	return app.AppCheck(ctx)
}

func (conf *Config) Access(kong *pdk.PDK) {
	once.Do(func() {
		verifier, initErr = initFirebaseAppCheck(conf)
		if initErr == nil && conf.CacheTTL > 0 {
			cacheClient = cache.New(
				time.Duration(conf.CacheTTL)*time.Second,
				time.Duration(conf.CacheTTL*2)*time.Second,
			)
		}
	})

	if initErr != nil {
		kong.Response.Exit(500, []byte("Internal Server Error"), nil)
		return
	}

	token, _ := kong.Request.GetHeader("X-Firebase-AppCheck")
	if token == "" {
		kong.Response.Exit(401, []byte("Unauthorized: missing App Check token"), nil)
		return
	}

	if conf.CacheTTL > 0 {
		if _, found := cacheClient.Get(token); found {
			return
		}
	}

	_, err := verifier.VerifyToken(token)
	if err != nil {
		kong.Response.Exit(401, []byte("Unauthorized: invalid App Check token"), nil)
		return
	}

	if conf.CacheTTL > 0 {
		cacheClient.Set(token, true, cache.DefaultExpiration)
	}
}

func main() {
	const (
		Version  = "0.1.0"
		Priority = 1
	)
	server.StartServer(New, Version, Priority)
}
