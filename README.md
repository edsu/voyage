voyage
======

Displays a stream of circulation activity from a Voyager ILS. You'll 
need a read-only connection to Voyager's Oracle instance for this to work.

Install
=======

    % sudo apt-get install nodejs`
    % npm install
    % cp config.json.template config.json
    # add db settings to config.json
    % coffee server.coffee
