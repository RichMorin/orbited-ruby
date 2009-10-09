# Orbited-Ruby

> Orbited provides a pure JavaScript/HTML socket in the browser. It is a web router and firewall that allows you to integrate web applications with arbitrary back-end systems. You can implement any network protocol in the browser—without resorting to plugins.
##### From Orbited.org

![Orbited-Ruby Logo](http://img505.imageshack.us/img505/1465/orbitedruby.png "Orbited-Ruby")

All the awesomeness of Orbited.

Packed neatly into your Ruby workflow.

    #example.ru
    require 'lib/orbited'
    Orbited::Middleware.install self
    

Want to give it a try?

    $ rackup -s thin --env none --port 3500 example.ru

### !! Only works with thin for now. Rack needs to codify asynchronous callbacks.

Then open up

    http://localhost:3500/static/test_socket.html

Click "connect", watch messages from from irc.freenode.net:6667 come into your browser. That is about the extent that this project works right now.

You should see this, more or less:

![output from socket test](http://img233.imageshack.us/img233/2808/output.png "socket test output")
