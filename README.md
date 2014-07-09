# Nginx Log Aggregator

## Motivation

I wrote this script to aggregate nginx logs and search them for problems
(Problem = HTTP response code >= 400 )

This script basically works as follows:

* It parses nginx log configuration according to log_format statement
  passed in configuration file

* Then it filters out entries which generated too little errors

* Then it renders ERB template which currently (as of 2014-08-09) prints
  HTML email message  (suitable for passing to `sendmail -t`)




## Configuration

Configuration files are YAML-formatted
They have structure like this:
```yaml
default:
    title: "default title"
config_1:
    title: "config 1"

config_2:
    title: "config 2"

```
each key declares one configuration

'default' key consist of default values - they can be overriden by
setting value for key in other configuration




## Running

Run script like this:
./aggregate-nginx.rb -c CONFIGURATION -f CONFIG_FILE 

where CONFIGURATION is yaml configuration file
and CONFIG is config key from file to use



