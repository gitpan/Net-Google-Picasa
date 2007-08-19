##############################################################################
#
# Net::Google::Picasa Perl module to interface to the Google Picasa XML Feed
#
# Info on Google API
# http://code.google.com/apis/picasaweb/overview.html
# http://code.google.com/apis/picasaweb/gdata.html
#

package Net::Google::Picasa;

use strict;

use vars qw($VERSION @ISA @EXPORT @EXPORT_OK);

#
# Includes
#

use Carp;
use Data::Dumper;
use XML::Element;
use XML::Simple;
use LWP::UserAgent;
require Exporter;

#
# End Includes
#

@ISA = qw(Exporter AutoLoader);

@EXPORT = qw(

);

$VERSION = '0.01';


# new - constructor
#
# @TODO most of that google related data should move elsewhere
sub new {
	my $class = shift;

	my $self = {
		Email => undef,
		Passwd => undef,
		Login => undef,
		service => 'lh2',
		source => "Net::Google::Picasa $Picasa::VERSION",
		lwp => undef,
		request => undef,
		google => "http://picasaweb.google.com/data/feed/api/user/",
		google_auth => "https://www.google.com/accounts/ClientLogin",
		_google_schema => "http://schemas.google.com/g/2005#kind",
		_google_term => "http://schemas.google.com/photos/2007#",
		auth_token => undef,
		@_
		
		};
	bless($self, $class);
	$self->setup_lwp();
	return($self);	
}

# authenticate - login to Google Picasa
#
# authenticate expects blessed parameters Email & Passwd be set.
# No parameters but it returns the auth token
#
# @return google auth token or 0 on failure
sub authenticate {
	my $self = shift;

	my $res;
        my $is_authed = 0;

	$res = $self->_lwp->post($self->{google_auth},
                               [
                               accountType => "HOSTED_OR_GOOGLE",
                               Email => $self->email(),
			       Passwd => $self->passwd(),
                               service => $self->_service(),
                               source => $Picasa::VERSION
                               ]);  
	foreach (split(/\n/, $res->as_string)) {
		if( /^Auth=/ ) {
			s/(Auth=)(.*)/$2/;
			$self->_auth_token($_);
                        $is_authed = 1;
		}
	}
        if ($is_authed == 1) {
	        return($self->_auth_token());
        }

        if ($self->debug()) {
                carp("Failed to authenticate to Google ClientLogin interface.");
        }

        return(0);
}

# list_album_photos - Lists the photos in an album.
#
# @param $param paramater hash
sub list_album_photos {
        my $self = shift;
        my $params = shift;

        my $raw_content;
        my $status_code;
        my $xml;
        my @return;

        my $url = $self->{google} . $params->{user} . "/album/" . 
                $params->{album} . "?kind=photo";

        $raw_content = $self->_get_google($url);
        ($status_code, $xml) = $self->_parse_google_response($raw_content);

        if ($status_code != 200) {
                return(0);
        }

        if (!$xml) {
                return(0);
        }

        return($xml); 
}




# add_album - Adds an album to a Picasa web gallery
#
# authenticates with google and creates a Picasa web album.
#
# @param $params parameter hash with information to create album
# @return google response
sub add_album {
	my $self = shift;
	my $params = shift;

        my $response;
        my $url;

	my $content = $self->_xml_add_album($params);

        $url = $self->_google() . $self->_login();

        if ($self->debug()) {
                carp("Creating Album\nURL:$url\nXML:\n$content\n");
        }

        $response = $self->_post_google($content, $url);

        if ($self->debug()) {
                carp("Creating Album Response:\n$response\n");
        }
        return($response);
}

# post_photo - upload an image to a Picasa web album
#
# POST http://picasaweb.google.com/data/feed/api/user/<LOGIN>/album/<ALBUMNAME> 
#
# @param $photo the file to upload
# @param $album the album to upload to
# @param $params parameters used in XML attached to image
# @return XML::Simple breakdown of the XML response from google 
sub post_photo {
	my $self = shift;
        my $photo = shift;
        my $album = shift;
	my $params = shift;

        my $res;
        my $req;
        my $url;
        my $status_line;
        my $status_code;
        my $binary_image = '';
        my $xml;


        # if image doesn't exist warn and return 
	if (!-e $photo) {
		carp "Cannot find " . $photo . "\n";
		return(0);
	}
        #Google expects album on URL to be whitespace free
        $album =~ s/\s+//g;
        $params->{title} = $photo;
        my $content = $self->_xml_post_photo($params);
        $url = $self->_google() . $self->_login() . '/album/' . $album;
        open(IMAGE, "<$photo");
        binmode(IMAGE);
        while (<IMAGE>) {
                $binary_image .= $_;
        }
        close(IMAGE);

        if ($self->debug()) {
                carp "Atom XML Request:\n$content\n";
        }

        $res = $self->_post_google_image($content, $url, $binary_image);

        if ($self->debug()) {
                carp "Picasa Response:\n" . $res->as_string . "\n";
        }
        ($status_code, $xml) = $self->_parse_google_response($res->as_string);

        if ($status_code != 201) {
                return(0);
        }

        # The response should include XML if the operation was successful.
        if (!$xml) {
                return(0);
        }

        # If google didn't return the same size as the file there must've been
        # a problem
        if ($xml->{'gphoto:size'} != -s $photo) {
                return(0);
        }
        
        if ($self->debug()) {
                carp(Dumper($xml));
        }

        return($xml)
}

	

# setup_lwp - initializes the LWP class	
#
# @param optional LWP::UserAgent handle
# @return 1
sub setup_lwp {
	my $self = shift;
	
	if (@_) {
		$self->{LWP} = shift;
	}
	if (!$self->{lwp}) {
		$self->{lwp} = LWP::UserAgent->new();
	}
	return(1);
}

# _post_google - Send a post request to google.
#
# Sends a POST request to google containing the ATOM XML data for the request
# to be performed.  For multipart image requests you should use 
# _post_google_image 
#
# @param $content the ATOM XML Content of the request
# @param $url the URL to post to
# @return Google response as string
sub _post_google {
        my $self = shift;
        my $content = shift;
        my $url = shift;

	my $res;
	my $req;

        $req = HTTP::Request->new(POST => $url); 
	$req->add_part(HTTP::Message->new([Content_type => 'application/atom+xml'], $content));
	$req->header(
		Content_Type => 'application/atom+xml',
		Authorization => 'GoogleLogin auth=' . $self->_auth_token(),
		);
	$req->content($content);
	$self->{lwp} = undef;
	$self->setup_lwp();
	$res = $self->_lwp->request($req);

        return($res->as_string);

}

# _get_google - Send a GET request to google
#
# Sends a HTTP GET request to retrieve data from the Google Picasa API
#
# @param $url The URL To retrieve
# @return string containing HTTP response from LWP
sub _get_google {
        my $self = shift;
        my $url = shift;

        my $ua;
        my $res;

        $ua = LWP::UserAgent->new();
        $res = $ua->get($url);

        if (!$res) {
                carp("Unable to retrieve $url\n");
                return(0);
        }
        return($res->as_string);

}

# _post_google_image - Send a POST request to google to upload an image.
#
# Send a multipart POST request to google to upload an image.  The first part
# contains the ATOM XML data and the second part contains the binary image 
# data
#
# @param $content The ATOM XML content of the request
# @param $url the url to post to
# @param $image the binary conents of the file image
# @return google response as string
sub _post_google_image {
        my $self = shift;
        my $content = shift;
        my $url = shift;
        my $image = shift;
	my $res;
	my $req;

        $req = HTTP::Request->new(POST => $url); 
	$req->header(
		Content_Type => 'multipart/related',
		Authorization => 'GoogleLogin auth=' . $self->_auth_token(),
		);
	$req->add_part(HTTP::Message->new([Content_type => 'application/atom+xml'], $content));
        $req->add_part(HTTP::Message->new([Content_type => 'image/jpeg'], $image));

        # Why am I doing this here?
	$self->{lwp} = undef;
	$self->setup_lwp();
	$res = $self->_lwp->request($req);

        return($res->as_string);

}

# _parse_google_response - retrieve the status code and xml content of the 
# HTTP response from google
#
# @param $content - the content to parse
# @return HTTP Status Code
# @return XML::Simple reference to XML object
sub _parse_google_response {
        my $self = shift;
        my $content = shift;

        my $status_code;
        my $status_line;
        my $xml;

        # The first line of the response will have the status information.
        # HTTP/1.1 201 Created -- That's a successful photo upload response.
        $status_line = (split(/\n/, $content))[0];
        $status_code = (split(/\s+/, $status_line))[1];

        # Before we can be confident that the request was successful
        # we need to check the XML response for a couple of things
        foreach (split(/\n/, $content)) {
                if (/<?xml\ version='1\.0'/) {
                        $xml = XMLin($_);
                }
        }

        if ($xml) {
                return($status_code, $xml);
        }

        return($status_code);

}


#
# Public accessors
#

sub email {
	my $self = shift;

	if (@_) {
		$self->{Email} = shift;
	}
	return($self->{Email});
}

sub passwd {
	my $self = shift;

	if (@_) {
		$self->{Passwd} = shift;
	}

	return($self->{Passwd});
}

# debug - Accessor to the debug attribute.  Set to 0 to disable debugging or
# a true value such as 1 to enable.
#
# @param optional true/false values to set to debug attribute
# @return the status of the debug attribute
sub debug {
        my $self = shift;

        if (@_) {
                $self->{debug} = shift;
        }

        return($self->{debug});
}

#
# End Public Accessors
#

#
# Private Accessors
#

sub _service {
	my $self = shift;

	if (@_) {
		$self->{service} = shift;
	}

	return($self->{service});
}

sub _auth_token {
	my $self = shift;

	if (@_) {
		$self->{auth_token} = shift;
	}

	return($self->{auth_token});
}

sub _google_scheme {
	my $self = shift;

	return($self->{_google_schema});
}

sub _google_term {
	my $self = shift;

	return($self->{_google_term});
}

sub _lwp {
	my $self = shift;

	return($self->{lwp});
}

sub _google {
	my $self = shift;

	if (@_) {
		$self->{google} = shift;
	}

	return($self->{google});
}

sub _login {
	my $self = shift;

	my $email;
	if (@_) {
		$self->{login} = shift;
		return($self->{google});
	}
	if ($self->email()) {
		$email = $self->email();
		$email =~ s/(.*)(\@)(.*)/$1/;
		$self->{Login} = $email;
		return($self->{Login});
	}	
	return($self->{Login});
}
#
# End Private Accessors
#


#
# XML Builder Functions
#

# _xml_add_album - Builds the XML for adding an album
#
# @param $params the parameter information about the album for the XML
# @return the XML as string
sub _xml_add_album {
	my $self = shift;
	my $params = shift;

	my $return;

        my $root = $self->_xml_snip_root();
        my $entry = $self->_xml_snip_entry();

	if (!$params->{title}) {
                carp("No title set.  The title should be the album name\n");
                return(0);
        }
        $self->_xml_snip_title($entry, $params->{title});

        if ($params->{summary}) {
                $self->_xml_snip_summary($entry, $params->{summary});
        } else {
                $self->_xml_snip_summary($entry, '');
        }

        if ($params->{location}) {
                $self->_xml_snip_location($entry, $params->{location});
        } else {
                $self->_xml_snip_location($entry, '');
        }

	if ($params->{access}) {
		my $access = XML::Element->new('gphoto:access');
		$access->push_content($params->{access});
		$entry->push_content($access);
	}
	if ($params->{commentingEnabled}) {
		my $commenting = XML::Element->new('commentingEmabled');
		$commenting->push_content('true');
		$entry->push_content($commenting);
	}
	if ($params->{timestamp}) {
		my $timestamp = XML::Element->new('timestamp');
		$timestamp->push_content($params->{timestamp});
		$entry->push_content($timestamp);
	}
        # I'm still yet to figure out where in the actual web interface that
        # this can be checked.  but it doesn't cause failures so i'm leaving
        # it as is.
	if ($params->{keywords}) {
		my $group = XML::Element->new('media:group');
		my $keywords = XML::Element->new('media:keywords');
		$keywords->push_content($params->{keywords});
		$group->push_content($keywords);
		$entry->push_content($group);
	}
        # @TODO change this to the function
	my $category = XML::Element->new('category', (
			'scheme' => $self->_google_scheme,
			'term' => $self->_google_term . 'album'
		));
	$entry->push_content($category);

	$return = $root->as_XML;
	$return .= $entry->as_XML;

	return($return);
 
}

# _xml_post_photo - build the XML used to upload images into Picasa web albums
#
sub _xml_post_photo {
        my $self = shift;
        my $params = shift;

	my $return;

        my $root = $self->_xml_snip_root();
        my $entry = $self->_xml_snip_entry(0);

	if (!$params->{title}) {
                carp("No title set.  The title should be the filename\n");
                return(0);
        }
        $self->_xml_snip_title($entry, $params->{title});

        if ($params->{summary}) {
                $self->_xml_snip_summary($entry, $params->{summary});
        } 

        $self->_xml_snip_category($entry, 'photo');

	$return = $root->as_XML;
	$return .= $entry->as_XML;

	return($return);
 
}


#
# End XML Builder Functions
#

#
# XML Snippet Functions
#

sub _xml_snip_root {
        my $self = shift;
	return(XML::Element->new('~pi', text => 'xml version="1.0"'));
}

sub _xml_snip_entry {
        my $self = shift;
        my $detailed = 1; 
        if (@_) {
                $detailed = shift;
        }

        if ($detailed == 1) {
        	return(XML::Element->new('entry', (
				xmlns => 'http://www.w3.org/2005/Atom',
				'xmlns:media' => 'http://search.yahoo.com/mrss/',
				'xmlns:gphoto' => 'http://schemas.google.com/photos/2007'
				)));
        } else {
        	return(XML::Element->new('entry', (
				xmlns => 'http://www.w3.org/2005/Atom',
				)));
        }
}

# _xml_snip_category - add the category tag to the XML posted to google.
#
# This is a required part of the XML sent to google.  This is used by Google
# to determine if you're performing an album or photo operation.  If you upload
# a photo while passing album in $type you will create an album without an
# image with the title of the image name.
#
# @param $r_entry reference to the entry XML element
# @param $type type to place at the end of the term attribute
# @return return 1
sub _xml_snip_category {
        my $self = shift;
        my $r_entry = shift;
        my $type = shift;

	my $category = XML::Element->new('category', (
			'scheme' => $self->_google_scheme,
			'term' => $self->_google_term . $type
		));
	$r_entry->push_content($category);
        return(1);
}


sub _xml_snip_title {
        my $self = shift;
        my $r_entry = shift;
        my $title = shift;

        my $xml;

        $xml = XML::Element->new('title', 'type' => 'text');
	$xml->push_content($title);
	$r_entry->push_content($xml);
        return(1);
}

        
sub _xml_snip_summary {
        my $self = shift;
        my $r_entry = shift;
        my $summary = shift;

        my $xml;

        $xml = XML::Element->new('summary');
	$xml->push_content($summary);
	$r_entry->push_content($xml);
        return(1);
}

sub _xml_snip_location {
        my $self = shift;
        my $r_entry = shift;
        my $location = shift;

	my $xml;
       
        $xml = XML::Element->new('gphoto:location');
	$xml->push_content($location);
	$r_entry->push_content($xml);
        return(1);
}



#
# End XML Snippet Functions
#

1;
__END__

#
# Begin POD
#

=head1 NAME

Net::Google::Picasa - Perl module for accessing the Google Picasa web 
API

=head1 VERSION

Version 0.01

=head1 SYNOPSIS

        use Net::Google::Picasa;
        my $picasa = new Net::Google::Picasa(
                                        Email => 'email@gmail.com',
                                        Passwd => 'secret'
                                        );
        $picasa->authenticate();
        $picasa->add_album({ title => 'Album Name',
                                summary => 'Album description',
                                location => '37.24, -115.81',
                                access => 'public'
                            });
        $picasa->post_photo("/path/to/photo.jpg", "My Album", 
                                { summary => "My photo" });

=head1 DESCRIPTION

This module interfaces with the Google Picasa web API facilitating 
creating galleries and uploading photos.

***  THIS MODULE IS STILL IN AN EARLY ALPHA STAGE USE AT YOUR OWN  ***
***  RISK AND BE PREPARED FOR PARAMETERS CHANGING ORDER, A         ***
***  FUNCTION RENAME, OR ANY OTHER BREAKING ISSUES AT THIS EARLY   ***
***  DEVELOPMENT STAGE.                                            ***
                                
=head1 METHODS

=over 4

=item * Net::Google::Picasa->new()

Constructor.  Can be passed a list of attributes to configure the instance.
Here's a partial list: Email, Passwd, Login, source, lwp, auth_token

=item * $picasa->authenticate()

Perform the authentication with the Google webservice.  The Google
authorization token is stored in the auth_token attribute.

Returns the authorization token from Google.

=item * $picasa->list_album_photos()

List photos in an album

=item * $picasa->add_album()

Create a new Picasa web album.  Expects a hash reference containing the album
attributes.  Possible attributes are: title, summary, location, access, 
timestamp, keywords.  The title attribute is required as an album obviously needs a name.

=item * $picasa->post_photo("/path/to/image.jpg", "Album Name", HASHREF)

Upload a photo into a web gallery.  Three parameters are expected, the full
path to the image, the album to upload to, and a hash reference containing 
parameters describing the photo being uploaded.

=item * $picasa->setup_lwp()

Initialize the lwp handle.  The method accepts an active LWP handle if proxy 
support etc is needed.

=item * $picasa->email()

Accessor to the email attribute.  If called with no parameters returns the
current value of the email attribute.  Pass an email address as a parameter
to set the email address to use to authenticate to Google.

=item * $picasa->passwd()

Accessor to the password attribute.  If called with no parameters returns the
password used to authenticate to Google.  Pass the password to use for
authentication as a parameter to set the attribute.

=item * $picasa->debug()

Accessor to the debug attribute.  If passed a parameter it will set it to the
debug atribute.  Set to a true value such as 1 to enable debugging output or
a false value (0) to disable debugging output.  The return value is the
current value of the debug attribute.

=item * $picasa->_service()

=item * $picasa->_auth_token()

=item * $picasa->_google_scheme()

=item * $picasa->_google_term()

=item * $picasa->_lwp()

=item * $picasa->_google()

=item * $picasa->_login()


=item * $picasa->_xml_add_album()

Builds the ATOM XML for the POST request to Picasa to create an album.  
Expects a hash reference parameter.  title, summary, location, access, 
commentingEnabled, timestamp and keywords are possible keys.  The title key
is required to have a vlue.  The access key determines public/private album
status and Google expects one of those as the value.

=item * $picasa->_xml_post_photo()

Builds the ATOM XML for the POST requiest to Picasa to upload an image.  
Expects a hash reference parameter.  title and summary are used keys.  The
title key is required and must be the image name.  The summary key is optional.

=item * $picasa->_xml_snip_root()


=item * $picasa->_xml_snip_entry()


=item * $picasa->_xml_snip_title()


=item * $picasa->_xml_snip_location()


=item * $picasa->_xml_snip_summary()

=head1 AUTHOR

Craig Chamberlin, C<< <perlcasa at higherpass.com> >>

=head1 BUGS

Please report any bugs or feature requests to
C<bug-perlcasa-picasa at rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Net-Google-Picasa>.
I will be notified, and then you'll automatically be notified of progress on
your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Net::Google::Picasa

    You can also look for information at:

=over 4

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Net-Google-Picasa>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Net-Google-Picasa>

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Net-Google-Picasa>

=item * Search CPAN

L<http://search.cpan.org/dist/Net-Google-Picasa>

=back

=head1 ACKNOWLEDGEMENTS

=head1 COPYRIGHT & LICENSE

Copyright 2007 Craig Chamberlin, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

