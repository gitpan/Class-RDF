package Class::RDF::Store;

use base "Class::DBI";
use File::Temp;

our @Create_SQL = (<<'', <<'', <<'');
    create table ns (
	prefix char(16),
	uri char(255)
    );

    create table node (
	id integer primary key,
	created timestamp,
	value text,
	is_resource integer(1)
    );

    create table statement (
	id integer primary key,
	created timestamp,
	subject integer,
	predicate integer,
	object integer,
	context integer
    );


sub is_transient {
    my $class = shift;
    my %args  = ( TEMPLATE => "crdfXXXX", SUFFIX => ".db", UNLINK => 1, @_ );
    my $tmp   = File::Temp->new( %args );

    $class->set_db( Main => "dbi:SQLite:".$tmp->filename, "", "" );

    for my $st (@Create_SQL) {
	$class->db_Main->do($st);
    }
}

package Class::RDF::NS;

use Carp;
use base 'Class::RDF::Store';
use vars '$AUTOLOAD';
use strict;
use warnings;
no warnings 'redefine';

__PACKAGE__->table( "ns" );
__PACKAGE__->columns( All => qw( prefix uri ) );

our (%Cache, $Prefix_RE);

sub define {
    my ($class, %uri) = @_;
    while (my ($prefix, $uri) = each %uri) {
	my $ns = $class->find_or_create({ prefix => $prefix });
	$Cache{$prefix} = $ns;
	$ns->uri( $uri );
	$ns->update;
    }
    $class->_build_prefix_re;
}

sub export {
    my ($class, @prefixes) = @_;
    for my $prefix (@prefixes)  {
	my $ns = $class->retrieve($prefix);
	croak "Can't find prefix $prefix" unless $ns;
	my $uri = $ns->uri;

	no strict;
	*{"$prefix\::AUTOLOAD"} = sub {
	    my $object = shift;
	    (my $prop = $AUTOLOAD) =~ s/^.*:://o;
	    if (ref($object)) {
		$object->get_or_set( "$uri$prop", @_ );
	    } else {
		return "$uri$prop";
	    }
	};
    }
}

sub retrieve {
    my ($class, $prefix) = @_;
    return $Cache{$prefix} if $Cache{$prefix};
    my $ns = $class->SUPER::retrieve($prefix);
    $Cache{$prefix} = $ns;
    $class->_build_prefix_re;
}

sub load {
    my $class = shift;
    my $iter = $class->retrieve_all;
    while (my $ns = $iter->next) {
	$Cache{$ns->prefix} = $ns
    }
    $class->_build_prefix_re;
}

sub expand {
    my ($class, $uri) = @_;
    $uri =~ s/$Prefix_RE/$Cache{$1}->uri/es;
    return $uri;
}

sub _build_prefix_re {
    my $class = shift;
    my $list = join("|", keys %Cache);
    $Prefix_RE = qr/^($list):/;
}

package Class::RDF::Node;

use base "Class::RDF::Store";
#use overload '""' => \&as_string;
use Digest::MD5 'md5_hex';
use warnings;
use strict;

__PACKAGE__->table( "node" );
__PACKAGE__->columns( All => qw( id created value is_resource ) );
__PACKAGE__->autoupdate(1);
our %Cache;

sub new {
    my $class = shift;
    my $value = shift || "";
    return $class if ref $class and $class->isa(__PACKAGE__);

    return $Cache{$value} if $Cache{$value};

    my $is_resource = ($value =~ /^\w+:\S+$/o ? 1 : 0);
    my $obj =$class->find_or_create({ value => $value, is_resource => $is_resource });
    $Cache{$value} = $obj;
}

sub find {
    my ($class,$value) = @_;
    return unless defined $value;
    return $Cache{$value} if $Cache{$value};
    my ($found) = $class->search({ value => $value });
    $Cache{$value} = $found if $found;
    return $found;   
}

sub as_string {
    my $self = shift;
    return $self->value;
}

package Class::RDF::Statement;

use base "Class::RDF::Store";
use warnings;
use strict;

our @Quad = qw( subject predicate object context );

__PACKAGE__->table( "statement" );
__PACKAGE__->columns( All => "id", "created", @Quad );
__PACKAGE__->has_a( subject   => "Class::RDF::Node" );
__PACKAGE__->has_a( predicate => "Class::RDF::Node" );
__PACKAGE__->has_a( object    => "Class::RDF::Node" );
__PACKAGE__->has_a( context   => "Class::RDF::Node" );
__PACKAGE__->autoupdate(1);

__PACKAGE__->set_sql( RetrieveFull => <<'' );
    SELECT st.*, n.*
    FROM statement st, node n
    WHERE %s AND (
	   subject   = n.id 
	OR predicate = n.id 
	OR object    = n.id 
	OR context   = n.id ) 

__PACKAGE__->set_sql( RetrieveOrdered => <<'' );
    SELECT st.*, n.*
    FROM statement st, node n, node m
    WHERE %s AND (
	   subject   = n.id 
	OR predicate = n.id 
	OR object    = n.id 
	OR context   = n.id )
    AND m.id = object
    ORDER BY m.value %s

sub new {
    my ($class, @nodes) = @_;

    my @triple;
    for my $node (@nodes) {
	$node = Class::RDF::Node->new($node) unless ref $node;
	push @triple, $node;
    }
    $class->find_or_create({ subject	=> $triple[0],
			     predicate	=> $triple[1],
			     object	=> $triple[2],
			     context	=> $triple[3] });

}

sub value {
    my $self = shift;
    my $obj  = $self->object;
    return $obj->is_resource ?
	Class::RDF::Object->new($obj->value) : $obj->value;
}

sub triples {
    my $self = shift;
    my @t;
    foreach (qw(subject predicate object)) {
	my $node = $self->$_;
	if ($node and $node->can('value')) {
	    push @t, $node->value;
	} 
	else {
	    # XXX: why are we returning undef here?
	    return undef;
	}
    }
    return @t;
}

sub search {
    my $class = shift;
    my %args = ref($_[0]) ? %{$_[0]} : @_;

    $args{predicate} = Class::RDF::NS->expand( $args{predicate} )
	if exists $args{predicate} and not ref $args{predicate};

    my (@where, @vals);
    my @position = grep exists $args{$_}, qw{ subject predicate context };
    push @position, "object" if exists $args{object} and not $args{like};
    
    for my $position (@position) {
	push @where, "$position = ?";
	if ( ref $args{$position} ) {
	    push @vals, $args{$position};
	} else { 
	    my $node = Class::RDF::Node->find( $args{$position} ) 
		or return $class->_ids_to_objects([]);
	    push @vals, $node;
	}
    }

    if ( $args{like} ) {
	my @nodes = Class::RDF::Node->search_like( value => $args{object} );
	return $class->_ids_to_objects([]) unless @nodes;
	push @where, "object IN (" . join(",", map($_->id, @nodes)) . ")";
    }

    my $sth;
    if ( $args{order} ) {
	$sth = $class->sql_RetrieveOrdered( join(" AND ", @where), $args{order} );
    } else {
	$sth = $class->sql_RetrieveFull( join(" AND ", @where) );
    }

    my (@results, %nodes, %triples, %t, %n);
    eval {
	$sth->execute( @vals );
	$sth->bind_columns(\(
	    @t{qw{ id created subject predicate object context }},
	    @n{qw{ id created value is_resource }} ));

	while ($sth->fetch) {
	    unless ( exists $nodes{$n{id}} ) {
		$nodes{$n{id}} = Class::RDF::Node->construct(\%n);
	    }
	    unless ( exists $triples{$t{id}} ) {
		push @results, ( $triples{$t{id}} = {%t} );
	    }
	}
    };

    return $class->_croak("$class can't $sth->{Statement}: $@", err => $@)
	if $@;

    for my $st (values %triples) {
	for my $which (@Quad) {
	    $st->{$which} = $nodes{$st->{$which}} if $st->{$which};
	}
    }

    # warn scalar(@results), " statements fetched\n";
    # warn "< ", join(" ", map($_->id, @$_{@Quad})), " >\n" for @results;

    return $class->_ids_to_objects(\@results);
}

# ... we need to figure out where this belongs ...
#
# use Time::Piece;
# 
# sub ical_to_sql {
#     my ($class,$ical) = @_;
#     warn($ical);
#     my $t = Time::Piece->strptime($ical,"%Y%m%dT%H%M%SZ");
#     $t->strftime("%Y%m%d%H%M%S");
# }
# 
# sub timeslice {
#     my ($self,%p) = @_;
#     my $start = $p{start};
#     my $end = $p{end};
#     my @where;
#     # SQL for timestamp 
#     warn("time");
#     push @where, "created > " . $self->ical_to_sql($start) if $start;
#     push @where, "created < " . $self->ical_to_sql($end) if $end;
#     my $sql = join(" and ", @where); warn($sql); 
#     my @o = $self->retrieve_from_sql($sql);
# }

package Class::RDF::Object;

use Carp;
#use overload '""' => \&as_string;
use vars '$AUTOLOAD';
use strict;
use warnings;

sub new {
    my $class = shift;
    my ($uri, $context, $data, $base);
    $uri = shift unless ref $_[0] eq "HASH";
    $context = shift unless ref $_[0] eq "HASH";
    $data = shift if ref $_[0] eq "HASH";
    $base = shift if $_[0];
    $base ||= '_id:';		
    $uri ||= $base.sprintf("%08x%04x", time, int rand(0xFFFF));
    unless (ref $uri) {
	$uri = Class::RDF::Node->new($uri);
    }
    
    $context = Class::RDF::Node->find($context)
    	if $context and not ref $context;

    my $self = bless { 
		context => $context,
		uri => $uri, 
		triples => {},
		stub => 1 
	}, ref($class) || $class;
 
    while (my ($key, $vals) = each %$data) {
	for my $val (ref $vals eq 'ARRAY' ? @$vals : $vals) {
	    $val = $val->{uri}->value if ref($val) and $val->{'uri'};
	    my $st = Class::RDF::Statement->new( $uri, $key, $val );
	    $self->_add_statement($st);
	}
    }
    return $self;
}

sub _fetch_statements {
    my $self = shift;
    # warn "fetch_statements ", $self->uri->value, "\n";
    my $iter = Class::RDF::Statement->search( subject => $self->uri );
    while (my $st = $iter->next) {
	$self->_add_statement($st);
    }
    delete $self->{stub};
}

sub _add_statement {
    my ($self, $statement) = @_;
    push @{$self->{triples}{$statement->predicate->value} ||= []}, $statement;
}

sub statements {
    my $self = shift;
    $self->_fetch_statements if $self->{stub};
    return map( @$_, values %{$self->{triples}} );
}

sub triples {
    my $self = shift;
    $self->_fetch_statements if $self->{stub};
    return map( $_->triples, $self->statements  );
}

sub uri {
    my $self = shift;
    # read only because Goddess help us if an object's URI
    # changes in mid-flight
    return $self->{uri};
}

sub as_string {
    my $self = shift;
    return $self->uri->as_string;
}

sub context {
    my $self = shift;
    $self->{context} = shift if @_;
    return $self->{context} if $self->{context};  
}

sub get {
    my ($self, $prop) = @_;
    $self->_fetch_statements if $self->{stub};
    my $statements = $self->{triples}{$prop} or return;
    my @vals = map( $_->value, @$statements );
    return wantarray ? @vals : $vals[0];
}

sub set {
    my ($self, %args) = @_;
    $self->_fetch_statements if $self->{stub};
    while (my ($key, $val) = each %args) {
	if (exists $self->{triples}{$key}) {
	    $_->delete for @{$self->{triples}{$key}};
	    delete $self->{triples}{$key};
	}

	for my $value (ref($val) eq "ARRAY" ? @$val : $val) {
	    $value = $value->uri if ref($value) and $value->can('uri');
	    my $triple = Class::RDF::Statement->new(
			$self->uri->value, $key, $value, $self->context );
		    $self->_add_statement( $triple );
	}
    }
}

sub get_or_set {
    my ($self, $prop, @vals) = @_;
    if (@vals) {
	$self->set($prop => shift @vals);
    } else {
	return $self->get($prop);
    }
}

sub add {
    my ($self, %args) = @_;
    $self->_fetch_statements if $self->{stub};
    while (my ($key, $val) = each %args) {
        for my $value (ref($val) eq "ARRAY" ? @$val : $val) {
	    $value = $value->{uri} if ref($value) and $value->{uri};
	   
	    my $triple = Class::RDF::Statement->new(
		$self->uri, $key, $value, $self->context );
	    $self->_add_statement( $triple );
	}	
    }
}

sub remove {
    my ($self, %args) = @_;
    $self->_fetch_statements if $self->{stub};
    while (my ($key, $vals) = each %args) {
        my %remove;
        my @v = ref($vals) eq 'ARRAY' ? @$vals : ($vals);
	foreach my $o (@v) {
	    $o = $o->{uri}->value if ref($o) and $o->{uri};
	    $remove{$o} = 1;		
	}
        
	my $triples = $self->{triples}{$key};
	for (my $st = 0; $st < $#$triples; $st++) {
	    if ($remove{$triples->[$st]->object->value}) {
		$triples->[$st]->delete;
		splice @$triples, $st--, 1;
	    }
	}
    }
}

sub contains {
    my ($self, $prop, $val) = @_;
    $self->_fetch_statements if $self->{stub};
    return scalar grep( $_ eq $val, @{$self->{triples}{$prop}} )
	if exists $self->{triples}{$prop};
    return;
}

sub find {
    my ($class, $uri) = @_;
    my $node = Class::RDF::Node->find($uri);
    return $node ? $class->new($node) : undef;
}

sub find_or_create {
    my ($class, $args) = @_;
    my $obj;
    
    if (ref $args eq "HASH") {
	($obj) = $class->search( %$args );
    } else { # $args is really a uri
	$obj = $class->new( $args );
    }

    return $obj if $obj;
    return $class->new( @_ );
}

sub search {
    my ($class, $predicate, $object, $args) = @_;

    my %args = (ref($args) ? %$args : ());
    $args{predicate} = $predicate;
    $args{object} = $object if $object;
    my $iter = Class::RDF::Statement->search( %args );

    my (@results, %seen);
    while (my $st = $iter->next) {
	my $id = $st->subject->id;
	push @results, $seen{$id} = $class->new( $st->subject )
	    unless $seen{$id};
    }
    return( wantarray ? @results : $results[0] );
}

package Class::RDF;

use RDF::Simple::Parser;
use RDF::Simple::Serialiser;
use LWP::Simple ();
use Carp;
use strict;
use warnings;

our ($Parser, $Serializer);
our $VERSION = '0.11';

sub new {
    my $class = shift;
    Class::RDF::Object->new( @_ );
}

sub set_db {
    my $class = shift;
    Class::RDF::Store->set_db( Main => @_ );
    Class::RDF::NS->load;
}

sub is_transient {
    my $class = shift;
    Class::RDF::Store->is_transient;
}

sub define {
    my $class = shift;
    Class::RDF::NS->define(@_);
}

sub parser {
    my $class = shift;
    $Parser ||= RDF::Simple::Parser->new;
    return $Parser;
}

sub serializer {
    my $class = shift;
    $Serializer ||= RDF::Simple::Serialiser->new;
    return $Serializer;
}

sub parse {
    my ($class, %args) = @_;
    my @triples = $args{uri} ?
	$class->parser->parse_uri($args{uri}) :
	$class->parser->parse_rdf($args{xml});
    my %output;

    return unless @triples;

    # we care about getting the root object back first
    my $root = $triples[0][0];

    $args{context} ||= $args{uri};
    for my $triple (@triples) {
	Class::RDF::Statement->new(@$triple, $args{context});
	$output{$triple->[0]} ||= Class::RDF->new($triple->[0]);
    }
  
    my $first = delete $output{$root};
    return ($first, values %output);
}

sub serialize {
    my ($class, @objects) = @_;
    my @triples;
    for (@objects) {
	my @t = $_->triples;
	push @triples, @t;
    }
    $class->serializer->addns( $_->prefix, $_->uri )
	for Class::RDF::NS->retrieve_all;
    return $class->serializer->serialise(@triples);
}

*serialise = *serialise = \&serialize; # because I'm in love with her

1;

__END__

=head1 NAME

Class::RDF - Perl extension for mapping objects to RDF and back

=head1 SYNOPSIS

  use Class::RDF;

  # connect to an existing database
  Class::RDF->set_db( "dbi:mysql:rdf", "user", "pass" );

  # or use a temporary database
  Class::RDF->is_transient;

  # define xml namespace aliases, export some as perl namespaces.
  Class::RDF->define(
      rdf => "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
      rdfs => "http://www.w3.org/2000/01/rdf-schema#",
      foaf => "http://xmlns.com/foaf/0.1/",
  );
 	
  Class::RDF::NS->export( 'rdf', 'rdfs', 'foaf' );

  # eat RDF from the world
  my @objects = Class::RDF->parse( xml => $some_rdf_xml );
  @objects = Class::RDF->parse( uri => $a_uri_pointing_to_some_rdf_xml );

  # build our own RDF objects
  my $obj = Class::RDF::Object->new( $new_uri );
  $obj->rdf::type( foaf->Person );
  $obj->foaf::name( "Larry Wall" );

  # search for RDF objects in the database
  my @people = Class::RDF::Object->search( rdf->type => foaf->Person );
  for my $person (@people) {
      print $person->foaf::OnlineAccount->foaf::nick, "\n";
  }

  my $rdf_xml = Class::RDF->serialize( @people );

=head1 DESCRIPTION

  Class::RDF is a perl object layer over an RDF triplestore. 
  It is based on Class::DBI, the perl object / RDBMS package.
  Thus it works with mysql, postgresql, sqlite etc.
  Look in the sql/ directory distributed with this module for database schemas.

  It provides an 'rdf-y' shortcut syntax for addressing object properties.
  It also contains a triples-matching RDF API.
	  		
=head2 Class::RDF

=head2 METHODS

=head3 set_db

	Class::RDF->set_db( "dbi:mysql:rdfdb", "user", "pass );

Specify the DBI connect string, username, and password of your
RDF store. This method just wraps the set_db() method inherited
from Class::DBI. If you want a simple temporary data store, use
C<is_transient()> instead.

=head3 is_transient

	Class::RDF->is_transient;
	Class::RDF->is_transient( DIR => "/tmp" );

Specify a temporary data store for Class::RDF. Class::RDF uses File::Temp
to create an SQLite data store in a temporary file that is removed when
your program exits. Optional arguments to is_transient() are passed to
File::Temp->new as is, potentially overriding Class::RDF's defaults. See
L<File::Temp> for more details.

=head3 define

	Class::RDF->define('foaf','http://xmlns.com/foaf/0.1/');

Define an alias for an XML namespace. This needs to be done once per program, and is probably accompanied by a Class::RDF::NS->export('short_name').

This should be superseded by a loaded RDF model of namespaces and aliases which comes with the distribution and lives in the database. 
  
=head3 parse

	my @objects = Class::RDF->parse( xml => $some_xml );
	my @objects = Class::RDF->parse( uri => $uri_of_some_xml );

Parses the xml either passed in as a string or available at a URI, directly into the triplestore and returns the objects represented by the graph.

=head3 serialise 

	my $xml = Class::RDF->serialise( @objects );
	
Take a number of Class::RDF::Object objects, and serialise them as RDF/XML.

=head2 Class::RDF::Object

Class::RDF::Object is the base class for RDF perl objects.
It is designed to be subclassed:

	package Person; use base 'Class::RDF::Object';

Create a Class::RDF::Object derived object, then RDF predicate - object pairs can be set on it with a perlish syntax.

RDF resources - that is http:// , mailto: etc URIs, are automatically turned into Class::RDF::Objects when they are requested. To observe them as URIs they have to be referenced as $object->uri->value. RDF literals - ordinary strings - appear as regular properties.

	my $person = Person->new({foaf->mbox => 'mailto:zool@frot.org',
				  foaf->nick => 'zool'});
	print $person->uri->value;
	print $person->foaf::nick;
	print $person->foaf::mbox->uri->value;

=head2 METHODS

=head3 new ( [uri], [{ properties}], [context],[ baseuri] )
	
	my $obj = Class::RDF::Object->new({ rdf->type => foaf->Person, 
					    foaf->nick => 'zool'});
	# creates a stored object with blank node uri

	my $obj = Class::RDF::Object->new($uri);
	# creates (or retrieves) a stored object with a uri

	my $obj = Class::RDF::Object->new($uri,$context_uri);
	# creates (or retrieves) a stored object with a uri with a context


=head3 search ( predicate => object ) 
	
	my @found = $object->search( rdf->type => foaf->Person );
	my $found = $object->search( foaf->mbox );

Search for objects with predicate - object matching pairs. Can also supply a predicate without a corresponding object.

=head3 uri
	
	my $uri = $object->uri;
	print $uri->value;

Returns the uri of the object. 

=head2 Class::RDF::Statement

Class::RDF also provides the equivalent of a triples-matching API to the RDF store.

	my @statements = Class::RDF::Statement->search(subject => $uri);
	my @statements = Class::RDF::Statement->search(predicate => foaf->nick,
						       object => 'zool');
	my @statements = Class::RDF::Statement->search(context => $uri);

	my @triples = map {$_->triples} @statements;
	# three Class::RDF::Node objects

=head2 Class::RDF::Node

	my $node = Class::RDF::Node->new($uri); # create or retrieve
	my $exists = Class::RDF::Node->find($uri);

=head1 SEE ALSO

  Class::DBI(3pm), RDF::Simple(3pm)

  http://space.frot.org/grout.html - an RDF aggregator built on Class::RDF

=head1 TODO/BUGS

  lots! 

=head1 AUTHORS

Schuyler D. Erle <schuyler@nocat.net>

jo walsh <jo@frot.org>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2004 by Schuyler Erle & Jo Walsh

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.3 or,
at your option, any later version of Perl 5 you may have available.

=cut
