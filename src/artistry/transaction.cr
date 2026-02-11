module Artistry
  class Transaction
    def initialize(@tx : DB::Transaction)
    end

    # -- Artifact operations --

    def create(kind_or_code : String, data) : Artifact
      Artifact.create(kind_or_code, data)
    end

    def create(plugin : String, kind : String, data) : Artifact
      Artifact.create(plugin, kind, data)
    end

    def find(id : Int64) : Artifact?
      Artifact.find(id)
    end

    def find(slug : String) : Artifact?
      Artifact.find(slug)
    end

    def where(code : String, include_superseded : Bool = false) : Array(Artifact)
      Artifact.where(code, include_superseded)
    end

    def where(code : String, include_superseded : Bool = false, **conditions) : Array(Artifact)
      Artifact.where(code, include_superseded, **conditions)
    end

    # -- Tag operations --

    def tag(artifact : Artifact | Int64, name : String) : Nil
      Tag.tag(artifact, name)
    end

    def untag(artifact : Artifact | Int64, name : String) : Nil
      Tag.untag(artifact, name)
    end

    def sync_tags(artifact : Artifact | Int64, names : Array(String)) : Nil
      Tag.sync(artifact, names)
    end

    def tags_for(artifact : Artifact | Int64) : Array(Tag)
      Tag.for(artifact)
    end

    # -- Link operations --

    def link(from : Artifact | Int64, to : Artifact | Int64, rel : String, data = nil) : Link
      Link.create(from, to, rel, data)
    end

    def unlink(from : Artifact | Int64, to : Artifact | Int64, rel : String) : Nil
      found = Link.find(
        from.is_a?(Artifact) ? from.id : from,
        to.is_a?(Artifact) ? to.id : to,
        rel
      )
      found.try(&.delete)
    end

    def links_from(artifact : Artifact | Int64, rel : String? = nil) : Array(Link)
      Link.from(artifact, rel)
    end

    def links_to(artifact : Artifact | Int64, rel : String? = nil) : Array(Link)
      Link.to(artifact, rel)
    end

    # -- Transaction control --

    def rollback : Nil
      @tx.rollback
    end

    def commit : Nil
      @tx.commit
    end
  end
end
