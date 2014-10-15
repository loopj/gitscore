request = require "request"
async   = require "async"

HEADERS = {"User-Agent": "gitscore"}

authedRequest = (opts, cb) ->
  if process.env.GITHUB_API_TOKEN
    request(opts, cb).auth(process.env.GITHUB_API_TOKEN)
  else
    request(opts, cb)

class Github
  @user: (username, callback) ->
    authedRequest {url: "https://api.github.com/users/#{username}", headers: HEADERS}, (error, response, body) ->
      error = "Unable to lookup user #{username}" if !error and response.statusCode != 200
      responseContent = JSON.parse(body)
      error = "#{username} is an organization, gitscore only supports users." if responseContent.type == "Organization"
      callback(error, responseContent, response.headers["x-ratelimit-remaining"]) if callback

  @userRepos: (username, callback) ->
    authedRequest {url: "https://api.github.com/users/#{username}/repos", headers: HEADERS}, (error, response, body) ->
      error = "Unable to lookup user #{username}" if !error and response.statusCode != 200
      callback(error, JSON.parse(body), response.headers["x-ratelimit-remaining"]) if callback

  @userGists: (username, callback) ->
    authedRequest {url: "https://api.github.com/users/#{username}/gists", headers: HEADERS}, (error, response, body) ->
      error = "Unable to lookup user #{username}" if !error and response.statusCode != 200
      callback(error, JSON.parse(body), response.headers["x-ratelimit-remaining"]) if callback

  @userCombined: (username, callback) ->
    userData = {}
    throttle = 0

    async.auto
      user: (callback) =>
        @user username, (error, response, throttle_val) ->
          if error
            callback(error)
            return
          throttle = throttle_val
          userData.user = response
          callback()

      repos: (callback) =>
        @userRepos username, (error, response, throttle_val) ->
          if error
            callback(error)
            return
          throttle = throttle_val
          userData.repos = response
          callback()

      gists: (callback) =>
        @userGists username, (error, response, throttle_val) ->
          if error
            callback(error)
            return
          throttle = throttle_val
          userData.gists = response
          callback()

      , (err) ->
        callback err, userData, throttle

module.exports = Github
