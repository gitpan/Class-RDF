use 5.006;
use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    NAME              => 'Class::RDF',
    VERSION_FROM      => 'RDF.pm', # finds $VERSION
    PREREQ_PM         => {
	"Class::DBI"  => 0.95,
	"DBD::SQLite" => 0.29,
        "RDF::Simple" => 0.10,
    }, # e.g., Module::Name => 1.1
);
