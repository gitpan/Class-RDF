#!/usr/bin/perl

use Class::RDF;
use RDF::Simple::Parser;
use strict;

my %ns = (
    rdf => "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
    rdfs => "http://www.w3.org/2000/01/rdf-schema#",
    foaf => "http://xmlns.com/foaf/0.1/",
    geo => "http://www.w3.org/2003/01/geo/wgs84_pos#",
    scutter => "http://purl.org/net/scutter/"
);

Class::RDF->set_db( "dbi:mysql:rdf", "sderle", "" );
Class::RDF->define( %ns );
Class::RDF::NS->export('rdf','rdfs','scutter','foaf');
my %visited;
my @plan = "http://iconocla.st/misc/foaf.rdf";
my $seeAlso = Class::RDF::Node->new( rdfs->seeAlso );

while (1) {
    while (my $uri = shift @plan) {
	warn "$uri\n";

	$visited{$uri} = time;
	my $count = eval { Class::RDF->parse($uri) };
	if ($@) {
	    warn $@;
	    next;
	}
	warn "    + $count triples added\n";
    }
    my $iter = Class::RDF::Statement->search( predicate => $seeAlso );
    while (my $st = $iter->next) {
	my $prospect = $st->object->value;
	unless (exists $visited{$prospect}) {
	    push @plan, $prospect;
	    $visited{$prospect} = 0;
	    warn "    + adding $prospect to plan\n";
	}
    }
}
