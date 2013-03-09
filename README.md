

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

With hostname based passwords.... TODO: define this.




