voyage
======

Displays a stream of circulation activity from a Voyager ILS. You'll 
need a read-only connection to Voyager's Oracle instance for this to work.

Install
=======

voyage depends on [node-oracle](https://github.com/joeferner/node-oracle) 
for talking to the Voyager Oracle database. Make sure your Oracle 
environment is set up correctly according to the node-oracle documentation
before you attempt the following:

    % sudo apt-get install nodejs git
    % git clone https://github.com/edsu/voyage.git
    % cd voyage
    % npm install
    % cp config.json.template config.json
    # add db settings to config.json
    % coffee server.coffee
