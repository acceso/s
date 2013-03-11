

# Poor's man configuration management. #


This software is a wrapper around ssh.



## Things it does: ##


- Connects to machines.
- Resolves hostnames (right domain or hostname).
- Does authentication (right user, password or ssh key).
- Inserts commands into your bash history / bash profile.
- Future connections use the same SSH master process.
- (optionally) Execute a script on the host.
- (optionally) Loops over each matching host.



## Requirements ##

Perl modules you'll need:

- Net::OpenSSH
- Expect (if using su)
- Net::Server::Multiplex
- IO::Stty



## Sample config ##


    GLOBAL,prefix,.domain.lan,0,myuser,environment

    web01


This roughly translates to:

ssh myuser@prefixweb01.domain.lan



You need to set up an ssh key or password to log in as "myuser".

If "myuser" is not root, the script uses the configured command 
("su\_command" by default) and the configured class (Supass by default) 
to get root.

The sample backend just returns a string but you can write a more complex one.




## Multiple hosts ##


If you want to connect to several hosts consecutively you can use:


    ./s '/^serv/' host123

And the script will loop over serv1, serv2, ..., and host123.



## Scripts ##


You can also write a script, place it under "scripts/" ("scripts\_dir"),
and run it on several hosts.


This command just list the hosts:


    ./s -n -s script1 '/^host\d+/'


When sure you can do:


    ./s -s script1 '/^host\d+/'



